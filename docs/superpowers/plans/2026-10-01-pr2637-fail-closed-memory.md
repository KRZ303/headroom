# PR #2637 Fail-Closed Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure unresolved PROJECT-mode requests cannot open a fallback backend, execute memory operations, or teach the traffic learner.

**Architecture:** Make unresolved scope explicit at the storage-router boundary with a nullable database path/backend, then propagate request context through memory tool execution. Provider handlers must check the same unresolved scope before invoking memory tools or traffic learning. Preserve explicit `unresolved_project_fallback="global"` behavior.

**Tech Stack:** Python 3.11+, pytest, asyncio, local SQLite memory backend.

**Spec:** PR #2637 (`cdfa52a82b0f57529fdf026826830b0bbec5a074`) and the current-main TAM-550 fail-closed contract.

## Global Constraints

- Do not merge the stale PR branch wholesale; transplant only safeguards missing from current `main`.
- Preserve GLOBAL and USER storage behavior and explicit PROJECT-to-global opt-in.
- No unresolved PROJECT request may instantiate a backend or produce memory/learner writes.
- Update the contributor branch only after exact-head verification and focused validation.

## Review Focus

- Default unresolved PROJECT mode creates no backend; covered by router regression test.
- Explicit global fallback still returns a usable backend; covered by existing router tests.
- Custom and native memory tools fail closed before initialization; covered by handler isolation tests.
- Anthropic, OpenAI HTTP/chat, and Codex WebSocket learning skip unresolved requests; covered by provider learner tests.
- Resolved PROJECT requests retain project-scoped tool and learner behavior; covered by existing suites.

---

### Task 1: Storage-router sentinel

**Files:**
- Modify: `headroom/memory/storage_router.py`
- Test: `tests/test_memory_storage_router.py`

**Interfaces:**
- Produces: `ResolvedScope.db_path: Path | None`, `BackendRouter.backend_for() -> tuple[LocalBackend | None, ResolvedScope]`, and `scope_for()`.
- Consumed by: Task 2 request-resolution guards.

- [ ] Add a regression assertion that unresolved default mode returns `backend is None`, `scope.db_path is None`, and leaves `open_backends()` empty.
- [ ] Run the focused test and verify it fails on current main.
- [ ] Return the unresolved sentinel before `_get_or_create_backend`; retain explicit global fallback.
- [ ] Run the storage-router suite and verify it passes.
- [ ] Commit the task.

### Task 2: Memory operation fail-closed propagation

**Files:**
- Modify: `headroom/proxy/memory_handler.py`
- Modify: `headroom/proxy/handlers/openai.py`
- Test: `tests/test_memory_handler_project_isolation.py`
- Test: `tests/test_memory_handler_native_ops.py`
- Test: `tests/test_openai_codex_ws_lifecycle.py`

**Interfaces:**
- Consumes: Task 1 nullable backend/scope.
- Produces: a public unresolved-scope predicate plus request-context-aware custom/native tool execution.
- Consumed by: Task 3 learner guards.

- [ ] Add regression tests proving unresolved custom/native tools return a structured error without backend creation or writes.
- [ ] Run focused tests and verify expected failures.
- [ ] Thread request context through tool dispatch, resolve before initialization/operation, and fail closed on the sentinel.
- [ ] Run memory handler and OpenAI lifecycle suites and verify they pass.
- [ ] Commit the task.

### Task 3: Provider traffic-learning guards

**Files:**
- Modify: `headroom/proxy/handlers/anthropic.py`
- Modify: `headroom/proxy/handlers/openai.py`
- Test: `tests/test_memory_handler_project_isolation.py`
- Test: `tests/test_openai_responses_traffic_learner.py`
- Test: `tests/test_openai_codex_ws_lifecycle.py`

**Interfaces:**
- Consumes: Task 2 unresolved-scope predicate.
- Produces: fail-closed learner behavior across Anthropic, OpenAI responses/chat, and Codex WebSocket paths.

- [ ] Add provider-specific regression tests showing learner callbacks are not invoked for unresolved PROJECT requests.
- [ ] Run focused tests and verify expected failures.
- [ ] Guard every learner entry point before backend binding or callbacks.
- [ ] Run all affected memory/provider tests, Ruff, formatting, compileall, and mypy.
- [ ] Commit the task and perform a whole-branch review against current main.
