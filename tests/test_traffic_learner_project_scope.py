from __future__ import annotations

import asyncio
import json
import sqlite3
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

from headroom.memory import storage_router
from headroom.memory.storage_router import MemoryStorageMode, RequestContext
from headroom.memory.traffic_learner import ExtractedPattern, PatternCategory, TrafficLearner
from headroom.proxy.memory_handler import MemoryConfig, MemoryHandler


class _SQLiteBackend:
    def __init__(self, config: Any) -> None:
        self._config = config
        path = Path(config.db_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(path) as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS memories ("
                "id TEXT PRIMARY KEY, content TEXT NOT NULL, "
                "metadata TEXT NOT NULL DEFAULT '{}', "
                "entity_refs TEXT NOT NULL DEFAULT '[]', "
                "importance REAL NOT NULL DEFAULT 0.5, "
                "created_at TEXT)"
            )

    async def save_memory(self, **kwargs: Any) -> Any:
        memory_id = f"memory-{id(self)}"
        with sqlite3.connect(self._config.db_path) as conn:
            conn.execute(
                "INSERT INTO memories (id, content, metadata, entity_refs, importance) "
                "VALUES (?, ?, ?, '[]', ?)",
                (
                    memory_id,
                    kwargs["content"],
                    json.dumps(kwargs["metadata"]),
                    kwargs["importance"],
                ),
            )
        return SimpleNamespace(id=memory_id)


def _rows(path: Path) -> list[tuple[str, dict[str, Any]]]:
    if not path.exists():
        return []
    with sqlite3.connect(path) as conn:
        rows = conn.execute("SELECT content, metadata FROM memories").fetchall()
    return [(content, json.loads(metadata)) for content, metadata in rows]


@pytest.mark.asyncio
async def test_same_basename_projects_keep_learning_evidence_and_queue_isolated(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(storage_router, "LocalBackend", _SQLiteBackend)
    root_a = tmp_path / "a" / "repo"
    root_b = tmp_path / "b" / "repo"
    root_a.mkdir(parents=True)
    root_b.mkdir(parents=True)
    global_db = tmp_path / "global.db"
    handler = MemoryHandler(
        MemoryConfig(
            enabled=True,
            backend="local",
            db_path=str(global_db),
            storage_mode=MemoryStorageMode.PROJECT,
            storage_root=str(tmp_path / "scopes"),
        )
    )
    target_a = handler.resolve_target(
        "alice",
        RequestContext(
            headers={"x-headroom-cwd": str(root_a)},
            system_prompt="",
            base_user_id="alice",
        ),
        agent="claude",
        provider="anthropic",
    )
    target_b = handler.resolve_target(
        "alice",
        RequestContext(
            headers={"x-headroom-cwd": str(root_b)},
            system_prompt="",
            base_user_id="alice",
        ),
        agent="codex",
        provider="openai",
    )
    assert target_a is not None and target_b is not None
    assert target_a.identity != target_b.identity
    assert target_a.scope.db_path != target_b.scope.db_path

    learner = TrafficLearner(min_evidence=2)
    evidence = [{"role": "user", "content": "Never use tabs in this repository."}]
    await learner.on_messages(evidence, target=target_a)
    await learner.on_messages(evidence, target=target_b)
    await learner.on_messages(evidence, target=target_a)
    await learner.on_messages(
        [{"role": "user", "content": "No correction in this B request"}],
        target=target_b,
    )

    await learner.start()
    for _ in range(100):
        if len(_rows(target_a.scope.db_path)) == 1:
            break
        await asyncio.sleep(0.01)
    assert _rows(target_a.scope.db_path)[0][1]["evidence_count"] == 2
    assert _rows(target_b.scope.db_path) == []
    assert _rows(global_db) == []

    await learner.on_messages(evidence, target=target_b)
    for _ in range(100):
        if len(_rows(target_b.scope.db_path)) == 1:
            break
        await asyncio.sleep(0.01)
    await learner.stop()

    assert _rows(target_b.scope.db_path)[0][1]["evidence_count"] == 2
    assert _rows(global_db) == []

    restarted = TrafficLearner(min_evidence=2)
    await restarted.on_messages(evidence, target=target_a)
    await restarted.start()
    await restarted.on_messages(evidence, target=target_b)
    await restarted.stop()
    assert _rows(target_a.scope.db_path)[0][1]["evidence_count"] == 3
    assert _rows(target_b.scope.db_path)[0][1]["evidence_count"] == 3


@pytest.mark.asyncio
async def test_native_flush_uses_only_resolved_project_root_and_agent(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(storage_router, "LocalBackend", _SQLiteBackend)
    roots = {"claude": tmp_path / "a" / "repo", "codex": tmp_path / "b" / "repo"}
    for root in roots.values():
        root.mkdir(parents=True)

    class _Writer:
        def __init__(self, name: str) -> None:
            self.name = name

        def write(self, recommendations, project, *, dry_run):
            path = project.project_path / f"{self.name}.md"
            path.write_text("\n".join(rec.content for rec in recommendations))
            return SimpleNamespace(files_written=[path])

    class _Plugin:
        def __init__(self, name: str) -> None:
            self.writer = _Writer(name)

        def discover_projects(self):
            from headroom.learn.models import ProjectInfo

            root = roots[self.writer.name]
            return [ProjectInfo(root.name, root, root)]

        def create_writer(self):
            return self.writer

    plugins = {name: _Plugin(name) for name in roots}
    import headroom.learn.registry as registry

    monkeypatch.setattr(registry, "get_plugin", plugins.__getitem__)
    handler = MemoryHandler(
        MemoryConfig(
            enabled=True,
            backend="local",
            db_path=str(tmp_path / "global.db"),
            storage_root=str(tmp_path / "scopes"),
        )
    )

    def target(root: Path, agent: str):
        return handler.resolve_target(
            "alice",
            RequestContext(
                headers={"x-headroom-cwd": str(root)},
                system_prompt="",
                base_user_id="alice",
            ),
            agent=agent,
            provider="anthropic" if agent == "claude" else "openai",
        )

    target_a = target(roots["claude"], "claude")
    target_b = target(roots["codex"], "codex")
    assert target_a is not None and target_b is not None
    learner = TrafficLearner(min_evidence=2)
    await learner.start()
    for resolved, root in ((target_a, roots["claude"]), (target_b, roots["codex"])):
        for _ in range(2):
            await learner._accumulate(
                ExtractedPattern(
                    PatternCategory.ENVIRONMENT,
                    f"Use {root}/tool.py",
                    0.8,
                ),
                target=resolved,
            )
        for _ in range(100):
            if _rows(resolved.scope.db_path):
                break
            await asyncio.sleep(0.01)
        await learner.flush_to_file(resolved)

    assert (roots["claude"] / "claude.md").exists()
    assert not (roots["claude"] / "codex.md").exists()
    assert (roots["codex"] / "codex.md").exists()
    assert not (roots["codex"] / "claude.md").exists()

    global_handler = MemoryHandler(
        MemoryConfig(
            enabled=True,
            backend="local",
            db_path=str(tmp_path / "global.db"),
            storage_mode=MemoryStorageMode.GLOBAL,
        )
    )
    global_target = global_handler.resolve_target(
        "alice",
        RequestContext(headers={}, system_prompt="", base_user_id="alice"),
        agent="claude",
        provider="anthropic",
    )
    assert global_target is not None
    before = sorted(tmp_path.rglob("*.md"))
    await learner.flush_to_file(global_target)
    assert sorted(tmp_path.rglob("*.md")) == before

    rootless = handler.resolve_target(
        "alice",
        RequestContext(
            headers={"x-headroom-project-id": "explicit-only"},
            system_prompt="",
            base_user_id="alice",
        ),
        agent="claude",
        provider="anthropic",
    )
    unresolved = handler.resolve_target(
        "alice",
        RequestContext(headers={}, system_prompt="", base_user_id="alice"),
        agent="claude",
        provider="anthropic",
    )
    assert rootless is not None and rootless.project_root is None
    assert unresolved is None
    await learner.flush_to_file(rootless)
    assert sorted(tmp_path.rglob("*.md")) == before
    await learner.stop()
