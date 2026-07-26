from __future__ import annotations

import asyncio
import json
import sys
from types import SimpleNamespace
from typing import Any
from unittest.mock import patch

import httpx
from fastapi.testclient import TestClient

from headroom.memory.traffic_learner import TrafficLearner
from headroom.proxy.handlers.openai import (
    OpenAIHandlerMixin,
    _responses_input_to_learner_messages,
)
from headroom.proxy.server import ProxyConfig, create_app
from tests.test_openai_codex_ws_lifecycle import (
    _DummyOpenAIHandler,
    _FakeUpstream,
    _FakeWebSocket,
    _make_fake_websockets_module,
)


class _CompletedResponseTransport(httpx.AsyncBaseTransport):
    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            headers={"content-type": "application/json"},
            json={
                "id": "resp_test",
                "object": "response",
                "status": "completed",
                "model": "gpt-5",
                "output": [],
                "usage": {"input_tokens": 10, "output_tokens": 1},
            },
        )


class _RecordingLearner:
    def __init__(self) -> None:
        self._backend = None
        self._extractor = TrafficLearner(backend=None)
        self.message_batches: list[list[dict[str, Any]]] = []
        self.tool_results: list[dict[str, Any]] = []
        self.targets: list[Any] = []

    def extract_tool_results_from_messages(
        self,
        messages: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        return self._extractor.extract_tool_results_from_messages(messages)

    async def on_tool_result(self, **tool_result: Any) -> None:
        self.targets.append(tool_result.pop("target"))
        tool_result.pop("agent_type")
        self.tool_results.append(tool_result)

    async def on_messages(self, messages: list[dict[str, Any]], **kwargs: Any) -> None:
        self.targets.append(kwargs["target"])
        self.message_batches.append(messages)


def _responses_input() -> list[dict[str, Any]]:
    return [
        {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": "Always return compact JSON."}],
        },
        {
            "type": "function_call",
            "call_id": "call_1",
            "name": "shell",
            "arguments": '{"cmd":"missing-command"}',
        },
        {
            "type": "function_call_output",
            "call_id": "call_1",
            "output": "command not found",
            "status": "failed",
        },
    ]


def _ws_frame(call_ids: list[str]) -> dict[str, Any]:
    input_items: list[dict[str, Any]] = []
    for call_id in call_ids:
        input_items.extend(
            [
                {
                    "type": "function_call",
                    "call_id": call_id,
                    "name": "shell",
                    "arguments": "{}",
                },
                {
                    "type": "function_call_output",
                    "call_id": call_id,
                    "output": "ok",
                    "status": "completed",
                },
            ]
        )
    return {"input": input_items}


def test_responses_input_normalizes_messages_and_tool_results() -> None:
    messages = _responses_input_to_learner_messages("Follow repository rules.", _responses_input())
    learner = TrafficLearner(backend=None)

    assert messages[0] == {"role": "system", "content": "Follow repository rules."}
    assert messages[1] == {"role": "user", "content": "Always return compact JSON."}
    assert learner.extract_tool_results_from_messages(messages) == [
        {
            "tool_name": "shell",
            "input": {"cmd": "missing-command"},
            "output": "command not found",
            "is_error": True,
            "call_id": "call_1",
        }
    ]


def test_unresolved_project_skips_openai_learner_entry_points() -> None:
    learner = _RecordingLearner()
    memory_handler = SimpleNamespace(is_project_unresolved=lambda _ctx: True)
    proxy = SimpleNamespace(traffic_learner=learner, memory_handler=memory_handler)

    async def run() -> None:
        await OpenAIHandlerMixin._observe_openai_responses_traffic(
            proxy,
            {"input": _responses_input()},
            request_id="responses-unresolved",
            request_context=object(),
        )
        await OpenAIHandlerMixin._observe_openai_chat_traffic(
            proxy,
            [{"role": "user", "content": "remember this"}],
            request_id="chat-unresolved",
            request_context=object(),
        )

    asyncio.run(run())
    assert learner.message_batches == []
    assert learner.tool_results == []


def test_responses_input_does_not_promote_unknown_role_to_user() -> None:
    messages = _responses_input_to_learner_messages(
        None,
        [
            {
                "type": "message",
                "content": [{"type": "input_text", "text": "Never expose ambient UI."}],
            },
            {
                "type": "message",
                "role": "developer",
                "content": [{"type": "input_text", "text": "Always follow runtime policy."}],
            },
        ],
    )

    assert messages == [
        {"role": "unknown", "content": "Never expose ambient UI."},
        {"role": "developer", "content": "Always follow runtime policy."},
    ]


def test_responses_http_request_reaches_traffic_learner(tmp_path) -> None:
    config = ProxyConfig(
        optimize=False,
        cache_enabled=False,
        rate_limit_enabled=False,
        cost_tracking_enabled=False,
        log_requests=False,
        ccr_inject_tool=False,
        ccr_handle_responses=False,
        ccr_context_tracking=False,
        image_optimize=False,
        memory_enabled=True,
        memory_db_path=str(tmp_path / "global.db"),
        memory_inject_tools=False,
        memory_inject_context=False,
        memory_mode="tool",
    )
    app = create_app(config)
    learner = _RecordingLearner()
    proxy = app.state.proxy
    proxy.traffic_learner = learner
    proxy.http_client = httpx.AsyncClient(transport=_CompletedResponseTransport())
    client = TestClient(app)

    response = client.post(
        "/v1/responses",
        headers={
            "authorization": "Bearer test-token",
            "x-headroom-cwd": str(tmp_path),
        },
        json={"model": "gpt-5", "input": _responses_input(), "stream": False},
    )

    assert response.status_code == 200, response.text
    assert len(learner.message_batches) == 1
    assert all(target is not None for target in learner.targets)
    assert learner.tool_results == [
        {
            "tool_name": "shell",
            "tool_input": {"cmd": "missing-command"},
            "tool_output": "command not found",
            "is_error": True,
        }
    ]


def _ws_frame(call_ids: list[str]) -> dict[str, Any]:
    """A response.create inner payload whose input carries one shell tool
    round-trip per call id."""
    input_items: list[dict[str, Any]] = []
    for cid in call_ids:
        input_items.append(
            {"type": "function_call", "call_id": cid, "name": "shell", "arguments": "{}"}
        )
        input_items.append(
            {
                "type": "function_call_output",
                "call_id": cid,
                "output": "ok",
                "status": "completed",
            }
        )
    return {"input": input_items}


def test_ws_response_create_baselines_and_dedups_replayed_transcript() -> None:
    handler = OpenAIHandlerMixin()
    learner = _RecordingLearner()
    handler.traffic_learner = learner
    target = SimpleNamespace(
        identity=("project", "ws-test", "alice", "codex", "openai"), agent="codex"
    )
    handler.memory_handler = SimpleNamespace(
        resolve_target=lambda *_args, **_kwargs: target
    )
    request_context = SimpleNamespace(base_user_id="alice", headers={})
    seen: dict[tuple[str, str, str, str, str], set[str]] = {}

    # First frame is the baseline: A and B are recorded as seen but NOT learned,
    # and preference extraction is skipped.
    asyncio.run(
        handler._observe_openai_ws_response_create(
            _ws_frame(["A", "B"]),
            seen_call_ids=seen,
            baseline=True,
            request_id="r",
            request_context=request_context,
        )
    )
    assert learner.tool_results == []
    assert learner.message_batches == []
    assert seen == {target.identity: {"A", "B"}}

    # Second frame replays A, B and appends C -> only C is learned.
    asyncio.run(
        handler._observe_openai_ws_response_create(
            _ws_frame(["A", "B", "C"]),
            seen_call_ids=seen,
            baseline=False,
            request_id="r",
            request_context=request_context,
        )
    )
    assert len(learner.tool_results) == 1
    assert seen == {target.identity: {"A", "B", "C"}}
    assert len(learner.message_batches) == 1

    # Third frame replays A, B, C and appends D -> only D is learned.
    asyncio.run(
        handler._observe_openai_ws_response_create(
            _ws_frame(["A", "B", "C", "D"]),
            seen_call_ids=seen,
            baseline=False,
            request_id="r",
            request_context=request_context,
        )
    )
    assert len(learner.tool_results) == 2  # C then D, never A/B again
    assert seen == {target.identity: {"A", "B", "C", "D"}}


def test_ws_reconnect_replay_adds_no_evidence() -> None:
    # A reconnect is a fresh connection: its first frame replays the whole
    # transcript, which is baselined, so nothing is re-learned.
    handler = OpenAIHandlerMixin()
    learner = _RecordingLearner()
    handler.traffic_learner = learner
    target = SimpleNamespace(
        identity=("project", "ws-test", "alice", "codex", "openai"), agent="codex"
    )
    handler.memory_handler = SimpleNamespace(
        resolve_target=lambda *_args, **_kwargs: target
    )
    request_context = SimpleNamespace(base_user_id="alice", headers={})
    seen: dict[tuple[str, str, str, str, str], set[str]] = {}

    asyncio.run(
        handler._observe_openai_ws_response_create(
            _ws_frame(["A", "B", "C", "D"]),
            seen_call_ids=seen,
            baseline=True,
            request_id="r",
            request_context=request_context,
        )
    )
    assert learner.tool_results == []
    assert seen == {target.identity: {"A", "B", "C", "D"}}
def test_ws_replay_dedup_is_scoped_to_resolved_target() -> None:
    handler = OpenAIHandlerMixin()
    learner = _RecordingLearner()
    target_a = SimpleNamespace(identity=("project", "a", "alice", "codex", "openai"), agent="codex")
    target_b = SimpleNamespace(identity=("project", "b", "alice", "codex", "openai"), agent="codex")

    class _MemoryHandler:
        def resolve_target(self, _user, request_context, **_kwargs):
            return target_a if request_context.headers["x-headroom-cwd"] == "/a" else target_b

    handler.traffic_learner = learner
    handler.memory_handler = _MemoryHandler()
    seen: dict[tuple[str, str, str, str, str], set[str]] = {}
    ctx_a = SimpleNamespace(base_user_id="alice", headers={"x-headroom-cwd": "/a"})
    ctx_b = SimpleNamespace(base_user_id="alice", headers={"x-headroom-cwd": "/b"})

    async def run() -> None:
        for ctx in (ctx_a, ctx_b):
            await handler._observe_openai_ws_response_create(
                _ws_frame(["shared"]),
                seen_call_ids=seen,
                baseline=True,
                request_id="baseline",
                request_context=ctx,
            )
        for ctx in (ctx_a, ctx_b):
            await handler._observe_openai_ws_response_create(
                _ws_frame(["shared", "new"]),
                seen_call_ids=seen,
                baseline=False,
                request_id="next",
                request_context=ctx,
            )

    asyncio.run(run())
    assert len(learner.tool_results) == 2
    assert seen[target_a.identity] == {"shared", "new"}
    assert seen[target_b.identity] == {"shared", "new"}


async def test_ws_learning_resolves_target_when_memory_injection_is_disabled(
    monkeypatch,
    tmp_path,
) -> None:
    monkeypatch.setenv("HEADROOM_MEMORY_INJECTION_MODE", "disabled")
    target = SimpleNamespace(
        identity=("project", "a", "alice", "codex", "openai"),
        agent="codex",
    )

    class _MemoryHandler:
        config = SimpleNamespace(
            inject_context=False,
            inject_tools=False,
            project_root_override="",
        )

        def __init__(self) -> None:
            self.contexts = []

        def resolve_target(self, _user, request_context, **_kwargs):
            self.contexts.append(request_context)
            return target

    memory = _MemoryHandler()
    learner = _RecordingLearner()
    handler = _DummyOpenAIHandler()
    handler.memory_handler = memory
    handler.traffic_learner = learner
    upstream = _FakeUpstream([], hold_after_events=True)
    client = _FakeWebSocket(
        frames=[
            json.dumps({"type": "response.create", "response": _ws_frame(["old"])}),
            json.dumps({"type": "response.create", "response": _ws_frame(["old", "new"])}),
        ],
        headers={
            "authorization": "Bearer test",
            "user-agent": "codex_cli_rs",
            "x-headroom-cwd": str(tmp_path),
        },
    )

    with patch.dict(sys.modules, {"websockets": _make_fake_websockets_module(upstream)}):
        await handler.handle_openai_responses_ws(client)

    assert len(memory.contexts) == 2
    assert all(context.project_root_override == str(tmp_path) for context in memory.contexts)
    assert len(learner.tool_results) == 1
    assert learner.targets
