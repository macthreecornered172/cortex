# Master Plan: Integration Test Engineer

## You are in PLAN MODE.

### Project
I want to build a **sidecar integration test suite** for the Cortex Phase 2 Sidecar.

**Goal:** build **end-to-end integration tests** that verify the full sidecar-to-gateway flow, agent-to-agent invocation, and provide reusable test helpers for the sidecar subsystem.

### Role + Scope
- **Role:** Integration Test Engineer
- **Scope:** I own all integration and invocation tests for the sidecar, plus shared test helpers. I do NOT own the sidecar implementation code, the gateway code, the HTTP handler unit tests, or packaging.
- **File I will write:** `/docs/cluster-mode/phase-2-sidecar/plans/integration-test.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

1. **Full Lifecycle Integration Tests** (`test/cortex/sidecar/integration_test.exs`)
   - Sidecar connects to the Cortex gateway via WebSocket, sends a `register` message, and appears in `Gateway.Registry`.
   - Sidecar sends periodic heartbeats; `Gateway.Health` acknowledges them and considers the agent alive.
   - Sidecar disconnects gracefully; the gateway marks the agent as disconnected and eventually removes it from the registry.
   - Sidecar reconnects after a connection drop; the agent re-registers and gets a new agent ID.
   - Agent calls `GET /roster` on the sidecar's local HTTP API and receives a list of all registered peers (including itself).
   - Agent calls `POST /status` on the sidecar; the status update propagates through the WebSocket to the gateway, and a `gateway_agent_status_changed` PubSub event is emitted.
   - Agent calls `POST /messages/:agent_id` on the sidecar; the message is routed via the gateway to the target agent's sidecar.
   - Cortex pushes a `task_request` to the sidecar via the WebSocket channel; the sidecar's state manager stores it and exposes it via `GET /task`.
   - Agent calls `POST /task/result` on the sidecar; the result is sent via WebSocket as a `task_result` message and acknowledged by the gateway.

2. **Agent-to-Agent Invocation Tests** (`test/cortex/sidecar/invoke_test.exs`)
   - Agent A calls `POST /ask/:agent_b_id` on its sidecar; the request is routed through Cortex as a `peer_request` to agent B's channel, agent B responds, and agent A receives the result.
   - Invocation that exceeds `timeout_ms` returns a structured timeout error.
   - Invoking a non-existent agent returns a structured `not_found` error.
   - `POST /ask/capable/:capability` routes the request to an agent that advertises the given capability.

3. **Test Helpers** (`test/support/sidecar_helpers.ex`)
   - `start_test_sidecar/1` — starts a sidecar process (Connection + State + HTTP server) connected to the test gateway, with configurable agent name, role, capabilities, and port.
   - `stop_test_sidecar/1` — gracefully shuts down a test sidecar.
   - `simulate_agent_response/3` — intercepts a `peer_request` on a sidecar and replies with a given payload (for testing invocation flows from the caller's perspective).
   - `assert_gateway_event/2` — waits for a specific gateway PubSub event type with optional payload matching; times out with a clear error if not received.
   - `http_get/2`, `http_post/3` — thin wrappers around an HTTP client (e.g., `Req` or `Finch`) that hit `localhost:<sidecar_port>` with JSON encoding/decoding.

## Non-Functional Requirements

1. **Determinism** — Tests must not depend on timing. Use explicit waits (`assert_receive` with timeouts, polling loops with bounded retries) rather than `Process.sleep`.
2. **Isolation** — Each test cleans up the gateway registry and stops its sidecar(s) in an `on_exit` callback. No test leaves state behind.
3. **Speed** — Target < 30 seconds for the full integration suite. Minimize real network waits by using short heartbeat intervals and tight timeouts in test config.
4. **Observability** — Tests verify that the correct telemetry events and PubSub events are emitted at each lifecycle step, not just that the happy path works.
5. **Async safety** — All sidecar integration tests use `async: false` because they share the global `Gateway.Registry` and potentially the same Phoenix endpoint.

## Assumptions / System Model

1. The Cortex Phoenix endpoint (including `AgentSocket` and `AgentChannel`) is started by the test application and available at a known URL during tests. The existing `CortexWeb.ChannelCase` and `Phoenix.ChannelTest` infrastructure handles this.
2. The sidecar's `Connection` module uses a WebSocket client (e.g., `Mint.WebSocket` or `:gun`) that can connect to the test Phoenix endpoint.
3. The sidecar's HTTP server (Bandit/Plug.Cowboy) starts on a dynamic port in tests to avoid port conflicts. Each test sidecar gets a unique port.
4. The sidecar's `State` module caches the roster and pending messages locally; the integration tests verify this cache is updated correctly after gateway interactions.
5. The gateway `Auth` module accepts a test token set via `CORTEX_GATEWAY_TOKEN` environment variable (same pattern used in Phase 1 integration tests).
6. The `peer_request` / `peer_response` flow requires the gateway to route messages between agent channels. If the gateway doesn't yet implement routing for `peer_request`, the invocation tests will need a stub or will depend on a routing module being added to the gateway.

## Data Model (as relevant to your role)

The integration tests work with these existing data structures:

| Struct | Module | Role in Tests |
|--------|--------|---------------|
| `RegisteredAgent` | `Cortex.Gateway.RegisteredAgent` | Verify registration populates all fields correctly |
| `RegisterMessage` | `Protocol.Messages.RegisterMessage` | Build registration payloads |
| `HeartbeatMessage` | `Protocol.Messages.HeartbeatMessage` | Build heartbeat payloads |
| `TaskRequestMessage` | `Protocol.Messages.TaskRequestMessage` | Push task requests to sidecar |
| `TaskResultMessage` | `Protocol.Messages.TaskResultMessage` | Verify task result submission |
| `PeerRequestMessage` | `Protocol.Messages.PeerRequestMessage` | Route agent-to-agent invocations |
| `StatusUpdateMessage` | `Protocol.Messages.StatusUpdateMessage` | Verify status propagation |

No new data models are introduced by the test suite.

## APIs (as relevant to your role)

The tests exercise two API surfaces:

### 1. Sidecar Local HTTP API (inward-facing, tested as a client)

| Method | Path | Test Coverage |
|--------|------|---------------|
| `GET` | `/health` | Verify sidecar reports connected/disconnected |
| `GET` | `/roster` | Verify roster lists all registered agents |
| `GET` | `/roster/:agent_id` | Verify single agent lookup |
| `GET` | `/roster/capable/:cap` | Verify capability-based discovery |
| `POST` | `/status` | Verify status update propagates to gateway |
| `POST` | `/messages/:agent_id` | Verify message routing |
| `GET` | `/messages` | Verify pending message retrieval |
| `GET` | `/task` | Verify task assignment retrieval |
| `POST` | `/task/result` | Verify task result submission |
| `POST` | `/ask/:agent_id` | Verify synchronous agent invocation |
| `POST` | `/ask/capable/:cap` | Verify capability-based invocation |

### 2. Gateway WebSocket Protocol (outward-facing, verified via PubSub + Registry)

Covered implicitly by checking that sidecar HTTP actions produce the correct downstream effects in the gateway (registry state changes, PubSub events, telemetry emissions).

## Architecture / Component Boundaries

```
Test Process
  |
  |-- start_test_sidecar(opts)
  |     |-- Sidecar.Connection (WebSocket to test Phoenix endpoint)
  |     |-- Sidecar.State (in-memory cache)
  |     \-- Sidecar.Router (Bandit on dynamic port)
  |
  |-- Gateway (started by test app supervision tree)
  |     |-- Gateway.Registry (GenServer)
  |     |-- Gateway.Health (GenServer)
  |     \-- AgentChannel (Phoenix Channel)
  |
  |-- assert_receive / assert_gateway_event (PubSub verification)
  \-- http_get / http_post (HTTP client to sidecar)
```

The test process orchestrates both sides. It starts sidecar(s), sends HTTP requests to them as if it were an agent, and verifies the effects on the gateway side by querying the registry and listening to PubSub events.

## Correctness Invariants (must be explicit)

1. **Registration invariant:** After `start_test_sidecar/1` returns, `Gateway.Registry.get(agent_id)` must return `{:ok, agent}` where `agent.name` matches the configured name.
2. **Heartbeat invariant:** After a heartbeat round-trip, the agent's `last_heartbeat` timestamp in the registry must be more recent than `registered_at`.
3. **Disconnect invariant:** After stopping a sidecar, the agent must eventually disappear from the registry (either immediately via `:DOWN` monitor or after health check timeout).
4. **Reconnect invariant:** After a reconnect, the agent must have a *new* agent ID (the gateway assigns a new UUID each time). The old ID must not be present in the registry.
5. **Roster consistency:** The roster returned by `GET /roster` must match `Gateway.Registry.list()` in agent count and IDs (modulo propagation delay).
6. **Message routing invariant:** A message sent via `POST /messages/:target_id` must arrive at the target agent's sidecar (verifiable via `GET /messages` on the target).
7. **Invocation invariant:** `POST /ask/:agent_id` must block until the target responds or the timeout expires. The response must contain the target's reply payload.
8. **Task flow invariant:** A `task_request` pushed by Cortex must be retrievable via `GET /task` on the sidecar. A `POST /task/result` must produce a `task_result` message on the WebSocket.

## Tests

### `test/cortex/sidecar/integration_test.exs`

| Test | Description | Verification |
|------|-------------|--------------|
| `connect_and_register` | Sidecar starts, connects, registers | `Registry.get(id)` returns agent with correct name/caps |
| `heartbeat_updates_registry` | Sidecar sends heartbeat | `agent.last_heartbeat` updated; heartbeat_ack received |
| `graceful_disconnect` | Stop sidecar | Agent removed from registry; PubSub event emitted |
| `reconnect_after_drop` | Kill WebSocket, wait for reconnect | New agent ID in registry; old ID gone |
| `roster_reflects_peers` | Start 2 sidecars, query roster from each | Both see each other in `GET /roster` response |
| `status_update_propagates` | Agent POSTs `/status` | Registry status updated; PubSub event emitted |
| `message_routing` | Agent A POSTs `/messages/:B`, agent B GETs `/messages` | Message appears in B's pending messages |
| `task_request_received` | Push `task_request` via channel | `GET /task` returns the task; state updated |
| `task_result_submitted` | Agent POSTs `/task/result` | `task_result` message received by gateway; PubSub event |

### `test/cortex/sidecar/invoke_test.exs`

| Test | Description | Verification |
|------|-------------|--------------|
| `ask_agent_by_id` | A calls `POST /ask/:B`, B responds | A receives B's response; round-trip completes |
| `ask_timeout` | A calls `POST /ask/:B`, B does not respond | A receives timeout error after `timeout_ms` |
| `ask_not_found` | A calls `POST /ask/:nonexistent` | A receives not_found error |
| `ask_by_capability` | A calls `POST /ask/capable/:cap` | Routed to agent with that capability; response returned |

## Benchmarks + "Success"

Benchmarks are N/A for integration tests. Success criteria:

| Metric | Target |
|--------|--------|
| All integration tests pass | 13 tests, 0 failures |
| Suite runtime | < 30 seconds |
| No flaky tests | 10 consecutive `mix test` runs with 0 failures |
| Reconnect test passes | Validates auto-reconnect with new agent ID |
| Invocation round-trip | < 500ms in test (localhost, no network latency) |

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### 1. In-process sidecar vs. separate OS process

**Decision:** Start the sidecar's OTP processes (Connection, State, Router) directly within the ExUnit test process tree, rather than spawning a separate OS process via `System.cmd` or `Port.open`.

**Why:** In-process testing gives us direct access to sidecar GenServer state for assertions, lets us use `Process.monitor` for lifecycle control, and avoids the complexity of port management, output parsing, and race conditions from OS process startup. The sidecar escript packaging (Sidecar Packaging Engineer's scope) can be tested separately as a smoke test.

**Tradeoff:** We don't test the actual escript entrypoint or CLI argument parsing. Those are covered by the Packaging Engineer's tests.

### 2. Dynamic ports for HTTP servers

**Decision:** Each test sidecar starts its HTTP server on port `0` (OS-assigned), and the test reads back the actual port from the sidecar state.

**Why:** Avoids port conflicts when multiple sidecars run in the same test or across concurrent test suites. The Phase 1 integration tests don't need ports (they use Phoenix.ChannelTest in-process), but sidecar tests hit real HTTP endpoints.

**Tradeoff:** Tests must query the sidecar for its port after startup, adding a small amount of setup complexity.

### 3. PubSub-based event verification vs. polling Registry

**Decision:** Use `assert_receive` on PubSub events as the primary verification mechanism, with direct `Registry` queries as secondary confirmation.

**Why:** PubSub events are the contract — downstream consumers (LiveView, telemetry) depend on them. Testing both the event emission and the registry state ensures the system is correct from multiple perspectives. `assert_receive` with timeouts is more deterministic than polling.

**Tradeoff:** Tests subscribe to PubSub in `setup`, which means they can receive events from other tests if not properly isolated. Mitigated by `async: false` and registry cleanup in `setup`.

---

## Risks & Mitigations (REQUIRED)

### 1. Sidecar WebSocket client not yet implemented
**Risk:** The `Sidecar.Connection` module may not be ready when integration tests are written. The tests depend on a working WebSocket client.
**Mitigation:** Write tests against the expected API (`start_test_sidecar/1`). If Connection is delayed, use `Phoenix.ChannelTest` helpers as a temporary stand-in for the WebSocket client side (same approach as Phase 1 integration tests). Tests can be written and reviewed before the sidecar code lands.

### 2. Gateway does not yet route `peer_request` messages
**Risk:** Phase 1 gateway handles `register`, `heartbeat`, `task_result`, and `status_update`, but agent-to-agent routing (`peer_request` forwarding) is likely a Phase 3 concern. The invoke tests may need gateway-side routing that doesn't exist yet.
**Mitigation:** The invoke test file (`invoke_test.exs`) can be tagged `@moduletag :pending` or `@tag :skip` until the routing infrastructure is added. The plan documents the expected behavior so the tests can be unblocked as soon as routing lands. Alternatively, implement minimal `peer_request` forwarding in the gateway as part of this phase.

### 3. Port conflicts in CI
**Risk:** If the CI environment runs multiple test suites in parallel, hardcoded ports could conflict.
**Mitigation:** Use port `0` (OS-assigned) for all sidecar HTTP servers. The Phoenix test endpoint already uses a random port via `server: false` in test config.

### 4. Reconnect test flakiness
**Risk:** Testing reconnection requires killing a WebSocket connection and waiting for the client to reconnect. Timing-dependent tests are prone to flakiness.
**Mitigation:** Configure the sidecar with a very short reconnect backoff in tests (e.g., `initial_backoff_ms: 50`). Use `assert_receive` with a generous timeout (5 seconds) rather than `Process.sleep`. Add a `sidecar_connected?/1` helper that polls connection state.

### 5. Test setup complexity
**Risk:** Starting both gateway and sidecar processes with proper config, tokens, and cleanup is complex. Tests may become hard to maintain.
**Mitigation:** Centralize all setup in `SidecarHelpers.start_test_sidecar/1` with sensible defaults. Each test only overrides what it needs. The `on_exit` callback in `setup` handles teardown automatically.

---

# Recommended API Surface

## Test Helper Module: `Cortex.SidecarHelpers`

```
start_test_sidecar(opts) :: {:ok, sidecar_info}
  opts: [name, role, capabilities, port, gateway_url, token, heartbeat_interval_ms]
  returns: %{pid: pid, agent_id: String.t(), port: integer, name: String.t()}

stop_test_sidecar(sidecar_info) :: :ok

simulate_agent_response(sidecar_info, request_id, response_payload) :: :ok

assert_gateway_event(event_type, opts \\ []) :: map()
  opts: [timeout: 5000, payload: %{}]

http_get(port, path) :: {:ok, status, body} | {:error, reason}
http_post(port, path, body) :: {:ok, status, body} | {:error, reason}
```

# Folder Structure

```
test/
  cortex/
    sidecar/
      integration_test.exs    # Full lifecycle integration tests (9 tests)
      invoke_test.exs          # Agent-to-agent invocation tests (4 tests)
  support/
    sidecar_helpers.ex         # Shared test helpers
```

Ownership:
- `test/cortex/sidecar/integration_test.exs` — Integration Test Engineer
- `test/cortex/sidecar/invoke_test.exs` — Integration Test Engineer
- `test/support/sidecar_helpers.ex` — Integration Test Engineer
- All sidecar implementation code (`lib/cortex/sidecar/*`) — other engineers

# Step-by-Step Task Plan

## Task 1: Test helpers module
- Create `test/support/sidecar_helpers.ex` with helper functions
- Verify: `mix compile --warnings-as-errors` (module compiles)
- Commit: `test(sidecar): add SidecarHelpers test support module`

## Task 2: Basic lifecycle integration tests
- Create `test/cortex/sidecar/integration_test.exs`
- Tests: connect_and_register, heartbeat_updates_registry, graceful_disconnect
- Verify: `mix test test/cortex/sidecar/integration_test.exs`
- Commit: `test(sidecar): add basic lifecycle integration tests`

## Task 3: Reconnect and multi-agent tests
- Add to `integration_test.exs`: reconnect_after_drop, roster_reflects_peers
- Verify: `mix test test/cortex/sidecar/integration_test.exs`
- Commit: `test(sidecar): add reconnect and multi-agent roster tests`

## Task 4: Status, messaging, and task flow tests
- Add to `integration_test.exs`: status_update_propagates, message_routing, task_request_received, task_result_submitted
- Verify: `mix test test/cortex/sidecar/integration_test.exs`
- Commit: `test(sidecar): add status, messaging, and task flow integration tests`

## Task 5: Agent-to-agent invocation tests
- Create `test/cortex/sidecar/invoke_test.exs`
- Tests: ask_agent_by_id, ask_timeout, ask_not_found, ask_by_capability
- Verify: `mix test test/cortex/sidecar/invoke_test.exs`
- Commit: `test(sidecar): add agent-to-agent invocation tests`

---

# Tighten the plan into 4-7 small tasks (STRICT)

### Task 1: Create test support helpers
- **Outcome:** `SidecarHelpers` module with `start_test_sidecar/1`, `stop_test_sidecar/1`, `assert_gateway_event/2`, `http_get/2`, `http_post/3`, and `simulate_agent_response/3`.
- **Files to create:** `test/support/sidecar_helpers.ex`
- **Exact verification:** `mix compile --warnings-as-errors`
- **Commit:** `test(sidecar): add SidecarHelpers test support module`

### Task 2: Lifecycle integration tests (connect, heartbeat, disconnect)
- **Outcome:** 3 passing tests covering the core sidecar lifecycle: registration, heartbeat round-trip, and graceful disconnect with registry cleanup.
- **Files to create:** `test/cortex/sidecar/integration_test.exs`
- **Exact verification:** `mix test test/cortex/sidecar/integration_test.exs --trace`
- **Commit:** `test(sidecar): add core lifecycle integration tests`

### Task 3: Reconnect, roster, and status tests
- **Outcome:** 3 passing tests: reconnect after connection drop (new agent ID), multi-agent roster query, and status update propagation.
- **Files to modify:** `test/cortex/sidecar/integration_test.exs`
- **Exact verification:** `mix test test/cortex/sidecar/integration_test.exs --trace`
- **Commit:** `test(sidecar): add reconnect, roster, and status integration tests`

### Task 4: Messaging and task flow tests
- **Outcome:** 3 passing tests: message routing between agents, task_request receipt via WebSocket, and task_result submission.
- **Files to modify:** `test/cortex/sidecar/integration_test.exs`
- **Exact verification:** `mix test test/cortex/sidecar/integration_test.exs --trace`
- **Commit:** `test(sidecar): add messaging and task flow integration tests`

### Task 5: Agent-to-agent invocation tests
- **Outcome:** 4 passing tests covering synchronous invocation by ID, timeout handling, not-found error, and capability-based routing.
- **Files to create:** `test/cortex/sidecar/invoke_test.exs`
- **Exact verification:** `mix test test/cortex/sidecar/invoke_test.exs --trace`
- **Commit:** `test(sidecar): add agent-to-agent invocation tests`

---

# CLAUDE.md contributions (do NOT write the file; propose content)

## From Integration Test Engineer

```
## Sidecar Integration Tests
- `mix test test/cortex/sidecar/integration_test.exs` — full sidecar-gateway lifecycle tests
- `mix test test/cortex/sidecar/invoke_test.exs` — agent-to-agent invocation tests
- Integration tests use `async: false` (shared Gateway.Registry state)
- Test sidecars use dynamic ports (port 0) to avoid conflicts
- `test/support/sidecar_helpers.ex` provides `start_test_sidecar/1` and friends
- Set `CORTEX_GATEWAY_TOKEN` in test setup for auth (same pattern as Phase 1 gateway tests)
```

# EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

- **Sidecar Integration Testing Strategy**: How the integration tests start both gateway and sidecar in-process, use PubSub for event verification, and HTTP clients for API validation.
- **Test Helper Design**: `SidecarHelpers` API and how `start_test_sidecar/1` wires up Connection + State + Router with test-appropriate config (short heartbeats, dynamic ports, test tokens).
- **Reconnection Testing**: Approach to testing auto-reconnect without flakiness — short backoffs, `assert_receive` with generous timeouts, explicit connection state checks.
- **Invocation Test Architecture**: How invocation tests use `simulate_agent_response/3` to make one sidecar respond to peer requests, enabling full round-trip testing without a real LLM agent.
- **Relationship to Phase 1 Integration Tests**: How sidecar integration tests extend the existing `Cortex.Gateway.IntegrationTest` patterns to cover the sidecar side of the protocol.

---

## READY FOR APPROVAL
