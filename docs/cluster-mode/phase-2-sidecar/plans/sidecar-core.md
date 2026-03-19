# Sidecar Core Engineer Plan

## You are in PLAN MODE.

### Project
I want to build the **Sidecar Core** for Cortex Cluster Mode Phase 2.

**Goal:** build the **sidecar's core infrastructure** — OTP application, configuration parsing, WebSocket client connection to the Cortex gateway, and local state management — so that a sidecar process can start alongside an agent, connect to Cortex, register itself, send heartbeats, receive tasks, and maintain resilient connectivity with automatic reconnection.

### Role + Scope
- **Role:** Sidecar Core Engineer
- **Scope:** I own the sidecar's OTP application, configuration, WebSocket client GenServer, and state manager GenServer. I do NOT own the local HTTP API (Sidecar HTTP API Engineer), the escript packaging (Sidecar Packaging Engineer), or integration tests across sidecar + gateway (Integration Test Engineer).
- **File I will write:** `docs/cluster-mode/phase-2-sidecar/plans/sidecar-core.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

- **FR1:** A sidecar configuration module (`Sidecar.Config`) that reads environment variables (`CORTEX_GATEWAY_URL`, `CORTEX_AGENT_NAME`, `CORTEX_AGENT_ROLE`, `CORTEX_AGENT_CAPABILITIES`, `CORTEX_AUTH_TOKEN`, `CORTEX_SIDECAR_PORT`, `CORTEX_HEARTBEAT_INTERVAL`), validates required fields, applies defaults for optional fields, and returns a validated config struct.
- **FR2:** A WebSocket client GenServer (`Sidecar.Connection`) that:
  - Connects to the Cortex gateway on startup using the configured URL.
  - Sends a `register` message immediately upon connection, using shared `Gateway.Protocol` modules for encoding.
  - Sends periodic `heartbeat` messages at the configured interval.
  - Handles incoming messages (`registered`, `task_request`, `peer_request`) by parsing with `Gateway.Protocol` and dispatching to the state manager.
  - Auto-reconnects on disconnect with exponential backoff (1s, 2s, 4s, 8s, ... capped at 30s).
  - Exposes connection status (`:connecting`, `:connected`, `:disconnected`, `:reconnecting`) to the state manager.
- **FR3:** A state manager GenServer (`Sidecar.State`) that:
  - Tracks the sidecar's current connection status.
  - Stores the assigned `agent_id` (received from the `registered` response).
  - Caches the mesh roster (list of peer agents, updated via gateway pushes or polling).
  - Stores pending inbound messages (task requests, peer requests) for the HTTP API to serve.
  - Tracks the current task assignment (if any).
- **FR4:** An OTP application module (`Sidecar.Application`) that starts a supervision tree containing the Config (as application env), State manager, Connection client, and (placeholder for) the HTTP server.
- **Tests required:** Unit tests for `Config` (parsing, validation, defaults), `Connection` (registration, heartbeat scheduling, reconnect backoff, message handling), and `State` (status tracking, message storage, roster caching).

## Non-Functional Requirements

- **Language/runtime:** Elixir, OTP. The sidecar runs as a separate OTP application within the Cortex umbrella (or as an escript later).
- **Local dev:** `mix test test/cortex/sidecar/` runs all sidecar core tests. No additional containers needed.
- **Observability:** Logger output for connection events (connect, disconnect, reconnect, registration success/failure). Telemetry events for connection state changes and heartbeat timing.
- **Safety:** The sidecar must never crash due to gateway unavailability. Connection failures are logged and retried with backoff. Invalid messages from the gateway are logged and discarded, not crashed on.
- **Documentation:** CLAUDE.md and EXPLAIN.md contributions proposed below.
- **Performance:** The sidecar is a lightweight process — one WebSocket connection, one state GenServer. No performance concerns at this scale.

---

## Assumptions / System Model

- **Deployment environment:** The sidecar runs as a local process alongside an agent. In dev, it runs via `mix run` or as part of the Cortex application. In production, it will be an escript (Packaging Engineer's scope).
- **Failure modes:**
  - **Gateway unreachable on startup** — sidecar starts, Connection enters `:connecting` state, retries with exponential backoff. HTTP API returns degraded status. Agent can still run; it just cannot query the mesh.
  - **Gateway disconnects mid-session** — Connection detects the closed WebSocket, transitions to `:reconnecting`, starts backoff reconnect loop. State manager retains cached roster and pending messages. On reconnect, Connection re-sends `register` to restore the session.
  - **Invalid gateway messages** — parsed with `Gateway.Protocol.parse/1`; failures are logged and discarded. The connection stays alive.
  - **State manager crash** — Supervisor restarts it. Connection pushes fresh state on next message. Cached roster and pending messages are lost (acceptable for MVP).
- **Delivery guarantees:** At-most-once for WebSocket messages. The sidecar does not implement message persistence or retry for outbound messages. If a heartbeat or task result is lost due to disconnect, it is simply re-sent after reconnection.
- **Multi-tenancy:** None. Single sidecar per agent, single gateway connection.

---

## Data Model (as relevant to this role)

### Sidecar.Config

```
%Sidecar.Config{
  gateway_url:        String.t(),         # required, e.g. "ws://cortex:4000/agent/websocket"
  agent_name:         String.t(),         # required
  agent_role:         String.t(),         # required
  agent_capabilities: [String.t()],       # required, parsed from comma-separated env var
  auth_token:         String.t(),         # required
  sidecar_port:       pos_integer(),      # default: 9090
  heartbeat_interval: pos_integer()       # default: 15_000 (ms)
}
```

**Validation rules:**
- `gateway_url` must be a non-empty string starting with `ws://` or `wss://`.
- `agent_name` must be a non-empty string matching `~r/^[a-zA-Z0-9_-]+$/`.
- `agent_role` must be a non-empty string.
- `agent_capabilities` must parse to a non-empty list of non-empty strings.
- `auth_token` must be a non-empty string.
- `sidecar_port` must be an integer between 1024 and 65535.
- `heartbeat_interval` must be a positive integer >= 1000 (ms).

### Sidecar.State (GenServer state)

```
%{
  agent_id:          String.t() | nil,        # assigned by gateway on registration
  connection_status: :connecting | :connected | :disconnected | :reconnecting,
  roster:            [map()],                 # cached list of peer agents
  pending_messages:  [map()],                 # inbound task_request / peer_request queue
  current_task:      map() | nil,             # current task assignment
  config:            Sidecar.Config.t()       # reference to config
}
```

### Sidecar.Connection (GenServer state)

```
%{
  config:            Sidecar.Config.t(),
  conn:              Mint.HTTP.t() | nil,     # Mint connection (if using Mint.WebSocket)
  websocket:         Mint.WebSocket.t() | nil,
  ref:               reference() | nil,       # Mint request ref
  state_pid:         pid(),                   # Sidecar.State GenServer
  status:            :connecting | :connected | :disconnected | :reconnecting,
  backoff_ms:        pos_integer(),           # current backoff delay (starts at 1000)
  heartbeat_timer:   reference() | nil        # timer ref for periodic heartbeats
}
```

**Versioning:** Protocol version is always `1` (from `Gateway.Protocol.supported_versions/0`). The sidecar hardcodes this for now.

---

## APIs (as relevant to this role)

### Sidecar.Config — Public Functions

| Function | Spec | Description |
|----------|------|-------------|
| `from_env/0` | `() -> {:ok, t()} \| {:error, [String.t()]}` | Read env vars, validate, return config struct |
| `from_env/1` | `(map()) -> {:ok, t()} \| {:error, [String.t()]}` | Same but with overrides map (for testing) |

### Sidecar.Connection — Public Functions

| Function | Spec | Description |
|----------|------|-------------|
| `start_link/1` | `(keyword()) -> GenServer.on_start()` | Start the WebSocket client |
| `send_message/2` | `(server, map()) -> :ok \| {:error, term()}` | Send a message to the gateway (used by HTTP API for task_result, status_update) |
| `status/1` | `(server) -> atom()` | Return current connection status |

### Sidecar.State — Public Functions

| Function | Spec | Description |
|----------|------|-------------|
| `start_link/1` | `(keyword()) -> GenServer.on_start()` | Start the state manager |
| `get_agent_id/1` | `(server) -> String.t() \| nil` | Return assigned agent_id |
| `get_status/1` | `(server) -> atom()` | Return connection status |
| `set_status/2` | `(server, atom()) -> :ok` | Update connection status |
| `set_agent_id/2` | `(server, String.t()) -> :ok` | Store assigned agent_id |
| `get_roster/1` | `(server) -> [map()]` | Return cached roster |
| `update_roster/2` | `(server, [map()]) -> :ok` | Replace cached roster |
| `push_message/2` | `(server, map()) -> :ok` | Enqueue an inbound message |
| `pop_messages/1` | `(server) -> [map()]` | Dequeue all pending messages |
| `get_current_task/1` | `(server) -> map() \| nil` | Return current task |
| `set_current_task/2` | `(server, map() \| nil) -> :ok` | Set or clear current task |
| `get_config/1` | `(server) -> Sidecar.Config.t()` | Return the config |

### Error Semantics

- `Config.from_env/0` accumulates all validation errors and returns them as a list of descriptive strings (same pattern as `Gateway.Protocol.Messages` validation).
- `Connection.send_message/2` returns `{:error, :not_connected}` if the WebSocket is not in `:connected` state.
- State functions never fail — they operate on in-memory GenServer state.

---

## Architecture / Component Boundaries

### Components I Own

1. **`Cortex.Sidecar.Application`** — OTP Application
   - Reads config via `Sidecar.Config.from_env/0` on startup; crashes if config is invalid (fail fast).
   - Starts supervision tree: `Sidecar.State` first, then `Sidecar.Connection`.
   - Placeholder child spec for `Sidecar.Router` (HTTP server, owned by HTTP API Engineer).
   - Strategy: `:rest_for_one` — if State crashes, Connection restarts too (Connection depends on State).

2. **`Cortex.Sidecar.Config`** — Configuration
   - Pure functional module, no GenServer.
   - Reads from `System.get_env/1`. Accepts an overrides map for testing.
   - Parses `CORTEX_AGENT_CAPABILITIES` as comma-separated: `"security-review,cve-lookup"` -> `["security-review", "cve-lookup"]`.

3. **`Cortex.Sidecar.Connection`** — WebSocket Client GenServer
   - Uses `Mint.WebSocket` for the WebSocket client (see Engineering Decisions below).
   - On `init/1`: starts connection attempt, schedules first heartbeat.
   - On successful WebSocket upgrade: sends `register` message via `Gateway.Protocol`.
   - On `registered` response: stores `agent_id` in `Sidecar.State`, transitions status to `:connected`.
   - On `task_request` / `peer_request`: pushes message to `Sidecar.State` pending queue.
   - On disconnect: transitions to `:reconnecting`, schedules reconnect with backoff.
   - Heartbeat: uses `Process.send_after/3` to schedule periodic heartbeats. Only sends if `:connected`.
   - Reconnect backoff: 1s -> 2s -> 4s -> 8s -> 16s -> 30s (capped). Resets to 1s on successful connect.

4. **`Cortex.Sidecar.State`** — State Manager GenServer
   - Simple key-value state with typed accessors.
   - No business logic — it is a data store for the Connection and HTTP API to coordinate through.

### Components I Call (owned by other teammates / Phase 1)

- `Cortex.Gateway.Protocol` — encode outbound messages (`RegisterMessage.to_map/1`, `HeartbeatMessage.to_map/1`) and parse inbound messages (for `registered`, `task_request`, `peer_request` responses).
- `Cortex.Gateway.Protocol.Messages.*` — message structs for building outbound messages.

### Components That Call Me (owned by other teammates)

- `Sidecar.Router` (HTTP API Engineer) — calls `State` to read roster, messages, task; calls `Connection.send_message/2` to send task results and status updates to the gateway.

### How Config Propagates

- Config is read once at startup from environment variables.
- The `Config` struct is passed to `State` and `Connection` as init args.
- No hot-reload of config for MVP. Changing config requires restarting the sidecar.

### Concurrency Model

- Two GenServer processes: `State` and `Connection`.
- `Connection` is the only process that touches the WebSocket. All outbound messages go through it.
- `State` is the only process that holds mutable application state. Both `Connection` and the HTTP API read/write through it.
- No contention concerns — GenServer mailboxes serialize access.

### Backpressure

- Inbound messages from the gateway are buffered in the `State` pending queue. If the agent never reads them, the queue grows unbounded. For MVP, this is acceptable — agents are expected to poll `/messages` regularly.
- Outbound messages are fire-and-forget through the WebSocket. No queuing of outbound messages during disconnect (they are dropped with an error return).

---

## Correctness Invariants

1. **Config validation is strict and fail-fast:** The sidecar application refuses to start if any required config field is missing or invalid. Error messages are descriptive.
2. **Connection status is always accurate:** `State.connection_status` always reflects the true state of the WebSocket connection. `Connection` updates `State` on every transition.
3. **Registration happens exactly once per connection:** On each new WebSocket connection, `Connection` sends exactly one `register` message. On reconnect, it re-registers (getting a new `agent_id`).
4. **Heartbeats only when connected:** Heartbeat timer fires periodically, but the heartbeat message is only sent if the connection status is `:connected`. No heartbeats are sent during `:reconnecting` or `:disconnected`.
5. **Backoff resets on success:** The exponential backoff counter resets to 1s whenever a WebSocket connection is successfully established.
6. **No crash on gateway failure:** Network errors, unexpected disconnects, and invalid messages from the gateway are all handled gracefully. The sidecar never crashes from external failures.
7. **State manager survives connection restarts:** If `Connection` restarts (due to crash), `State` retains its data. The `:rest_for_one` strategy means `Connection` restarts but `State` does not (unless `State` itself crashes).

---

## Tests

### Unit Tests

#### `test/cortex/sidecar/config_test.exs`

1. **Valid config:** All required env vars set -> `{:ok, %Config{}}` with correct values.
2. **Default values:** `CORTEX_SIDECAR_PORT` and `CORTEX_HEARTBEAT_INTERVAL` unset -> defaults to 9090 and 15000.
3. **Missing required fields:** Each required field missing individually -> error includes field name.
4. **All required fields missing:** -> error list contains all missing field names.
5. **Invalid gateway URL:** URL not starting with `ws://` or `wss://` -> validation error.
6. **Invalid port:** Non-numeric or out-of-range port -> validation error.
7. **Capabilities parsing:** `"a,b,c"` -> `["a", "b", "c"]`; `""` -> error; `"a"` -> `["a"]`.
8. **Overrides map:** `from_env/1` with overrides takes precedence over env vars.

#### `test/cortex/sidecar/state_test.exs`

1. **Initial state:** All fields have correct defaults (nil agent_id, :connecting status, empty roster, etc.).
2. **Agent ID:** `set_agent_id/2` then `get_agent_id/1` returns the ID.
3. **Connection status:** `set_status/2` then `get_status/1` returns the status.
4. **Roster:** `update_roster/2` then `get_roster/1` returns the roster.
5. **Messages:** `push_message/2` three times, then `pop_messages/1` returns all three and clears the queue.
6. **Current task:** `set_current_task/2` then `get_current_task/1`; clear with `set_current_task(nil)`.

#### `test/cortex/sidecar/connection_test.exs`

Testing the Connection GenServer requires mocking the WebSocket. Strategy: extract a `Sidecar.Connection.Transport` behaviour that wraps `Mint.WebSocket` calls. In tests, inject a mock transport that simulates connect/send/receive without a real WebSocket.

1. **Startup triggers connect:** On `init`, Connection calls the transport to establish a WebSocket connection.
2. **Registration on connect:** After successful WebSocket upgrade, Connection sends a `register` message with the correct payload (agent name, role, capabilities, auth token).
3. **Heartbeat scheduling:** After connection, heartbeats are sent at the configured interval.
4. **Registered response:** Receiving a `registered` message stores the agent_id in State and transitions status to `:connected`.
5. **Task request handling:** Receiving a `task_request` message pushes it to State pending messages.
6. **Peer request handling:** Receiving a `peer_request` message pushes it to State pending messages.
7. **Disconnect triggers reconnect:** On WebSocket close, Connection transitions to `:reconnecting` and schedules a reconnect.
8. **Exponential backoff:** Successive reconnect failures increase the delay: 1s, 2s, 4s, ... up to 30s cap.
9. **Backoff resets on success:** After a successful reconnect, backoff resets to 1s.
10. **send_message/2 when connected:** Returns `:ok` and sends the message via WebSocket.
11. **send_message/2 when disconnected:** Returns `{:error, :not_connected}`.
12. **Invalid inbound message:** Malformed JSON or unknown message type is logged but does not crash the process.

### Test Commands

```bash
mix test test/cortex/sidecar/config_test.exs
mix test test/cortex/sidecar/state_test.exs
mix test test/cortex/sidecar/connection_test.exs
mix test test/cortex/sidecar/
```

---

## Benchmarks + "Success"

N/A for the sidecar core. The sidecar is a lightweight process with one WebSocket connection and two GenServers. There is no algorithmic complexity or throughput concern worth benchmarking.

**Success criteria for this role** are functional:
- All tests pass.
- The sidecar starts, reads config from env, connects to the gateway via WebSocket, registers, and exchanges heartbeats.
- When the gateway goes down, the sidecar automatically reconnects with exponential backoff.
- When the gateway comes back, the sidecar re-registers and resumes heartbeats.
- The State GenServer correctly stores and serves agent_id, roster, pending messages, and connection status.
- The Connection GenServer never crashes from network errors or invalid messages.

---

## Engineering Decisions & Tradeoffs

### Decision 1: Mint.WebSocket vs :gun vs websocket_client for the WebSocket client

- **Decision:** Use `Mint.WebSocket` for the sidecar's WebSocket client.
- **Alternatives considered:**
  - `:gun` — Erlang HTTP/1.1 and HTTP/2 client with WebSocket support. Well-tested, but it is a full HTTP client with connection pooling and process-per-connection architecture that adds complexity we don't need.
  - `websocket_client` — thin Erlang WebSocket client. Less maintained, fewer users, limited documentation.
- **Why:** `Mint.WebSocket` is the idiomatic Elixir choice. It builds on `Mint.HTTP` (already a transitive dep of Phoenix), is actively maintained by the Elixir core team (DockYard/Dashbit), gives full control over the connection lifecycle (important for custom reconnect logic), and avoids adding a new dependency since Mint is already in the dep tree. The process-less architecture of Mint means we control exactly one GenServer for the connection — no hidden processes.
- **Tradeoff acknowledged:** `Mint.WebSocket` is lower-level than `:gun`. We must handle HTTP upgrade, frame encoding/decoding, and TCP socket management ourselves within the GenServer. This means more code in `Connection`, but it gives us full control over reconnection and error handling, which is exactly what the sidecar needs.

### Decision 2: Transport behaviour for testability vs direct Mint calls

- **Decision:** Extract a `Sidecar.Connection.Transport` behaviour that wraps Mint.WebSocket calls. The Connection GenServer calls the behaviour, not Mint directly.
- **Alternatives considered:** Test with a real WebSocket server (start a mini Phoenix endpoint in tests) or use Mox to mock Mint modules directly.
- **Why:** A behaviour interface makes Connection tests fast, deterministic, and independent of network. Starting a real Phoenix endpoint in unit tests is slow and fragile. Mocking Mint directly is brittle — Mint's API is low-level and changes would break mocks. A thin behaviour with `connect/2`, `send_frame/3`, `close/1` is stable and testable.
- **Tradeoff acknowledged:** An additional abstraction layer (the behaviour) adds a small amount of indirection. But the testing benefit is substantial — Connection tests run in milliseconds without network I/O.

### Decision 3: :rest_for_one supervision strategy

- **Decision:** Use `:rest_for_one` for the sidecar supervision tree, with State started before Connection.
- **Alternatives considered:** `:one_for_one` (independent restarts) or `:one_for_all` (restart everything together).
- **Why:** Connection depends on State (it pushes messages and status updates to State). If State crashes and restarts, Connection must restart too so it can get a fresh reference to the State process. If Connection crashes, State should NOT restart — it retains useful cached data. `:rest_for_one` gives exactly this behavior: children after the crashed one are restarted.
- **Tradeoff acknowledged:** If State crashes, Connection restarts and must reconnect to the gateway (losing the current WebSocket session). This is acceptable — the alternative (Connection holds stale State reference) would cause silent failures.

### Decision 4: Agent ID changes on reconnect

- **Decision:** On reconnect, the sidecar re-sends `register` and accepts a new `agent_id` from the gateway. The old `agent_id` is discarded.
- **Alternatives considered:** Persist the `agent_id` and attempt to resume the session (send the old ID in the register message).
- **Why:** The Phase 1 gateway assigns UUIDs on registration and has no session resumption protocol. Adding resumption would require gateway-side changes (out of scope for Phase 2). Re-registration is simple and correct — the agent gets a fresh identity, the old one is cleaned up by the gateway's health monitor.
- **Tradeoff acknowledged:** Other agents that cached the old `agent_id` (e.g., in peer_request routing) will see it as gone. The roster will update on the next refresh. For MVP, this staleness window is acceptable. Session resumption can be added in a future phase.

---

## Risks & Mitigations

### Risk 1: Mint.WebSocket not in the dependency tree

- **Risk:** `Mint.WebSocket` may not be an explicit dependency in `mix.exs`. It is a separate package from `Mint.HTTP` (which Phoenix pulls in).
- **Impact:** Compilation failure when `Sidecar.Connection` tries to use `Mint.WebSocket`.
- **Mitigation:** Check `mix.lock` for `mint_web_socket`. If absent, add `{:mint_web_socket, "~> 1.0"}` to `mix.exs` deps. This is a lightweight, well-maintained package.
- **Validation time:** ~2 minutes to check deps and add if needed.

### Risk 2: Gateway protocol message format mismatch between encode and parse paths

- **Risk:** The sidecar uses `Gateway.Protocol` to encode outbound messages (register, heartbeat) but the gateway's inbound parsing expects the JSON from a Phoenix Channel (which wraps messages differently than raw WebSocket JSON).
- **Impact:** The gateway rejects sidecar messages because the format doesn't match what the Channel expects.
- **Mitigation:** Study the Phase 1 `AgentChannel.handle_in/3` to understand the exact JSON shape expected. Phoenix Channels wrap messages in a `[join_ref, ref, topic, event, payload]` tuple format over the WebSocket, not plain JSON. The sidecar must speak the Phoenix Channel wire protocol, not raw JSON. This is a critical design point — validate by reading the Phoenix Channel transport source and testing with a real gateway.
- **Validation time:** ~15 minutes to trace the Phoenix Channel wire format and confirm the sidecar can speak it.

### Risk 3: Mint.WebSocket requires manual TCP/TLS socket management

- **Risk:** `Mint.WebSocket` is process-less and low-level. The GenServer must handle raw TCP messages (`:tcp`, `:ssl`), parse HTTP upgrade responses, and manage frame buffering. Getting this wrong leads to subtle connection bugs.
- **Impact:** Connection instability — dropped frames, incomplete messages, or failure to detect disconnects.
- **Mitigation:** Follow the `Mint.WebSocket` documentation and examples closely. The library provides `Mint.WebSocket.upgrade/4`, `Mint.WebSocket.decode/2`, and `Mint.WebSocket.encode/2` which handle the hard parts. Write thorough unit tests for each connection lifecycle phase (upgrade, data exchange, close, error). Consider using the `Fresh` library (a thin GenServer wrapper around Mint.WebSocket) if the manual approach proves too error-prone.
- **Validation time:** ~15 minutes to implement a minimal connect-send-receive spike with Mint.WebSocket against a local Phoenix endpoint.

### Risk 4: Phoenix Channel wire protocol complexity

- **Risk:** The sidecar needs to speak the Phoenix Channel protocol (not just raw WebSocket). Phoenix Channels use a specific serialization format: `[join_ref, ref, topic, event, payload]` JSON arrays over WebSocket. The sidecar must implement join, heartbeat (Phoenix-level, not Cortex-level), and the message envelope format.
- **Impact:** If the sidecar sends plain JSON objects, the Phoenix Channel will not recognize them. The sidecar needs to implement the Phoenix client protocol.
- **Mitigation:** Two options: (a) Implement the Phoenix Channel client protocol in Elixir (join topic, handle phx_reply, send Phoenix heartbeats). This is well-documented in the Phoenix.js source. (b) Add a raw WebSocket endpoint to the gateway that bypasses Phoenix Channels and accepts plain JSON. Option (a) is more work but requires no gateway changes. Option (b) is simpler for the sidecar but requires a new gateway endpoint (coordination with gateway team). **Recommendation:** Start with option (a) since the protocol is simple (5 message types) and avoid gateway changes.
- **Validation time:** ~15 minutes to read the Phoenix Channel serializer source and map out the required client-side messages.

### Risk 5: Sidecar and gateway running in the same BEAM node during development

- **Risk:** In dev, the sidecar modules live in the same Cortex project as the gateway. Starting both in the same `mix phx.server` could cause name conflicts (e.g., two `Sidecar.State` GenServers) or confusion about what is "sidecar" vs "gateway."
- **Impact:** Tests and dev workflows may behave differently from production (where the sidecar is a separate escript process).
- **Mitigation:** The sidecar application module (`Sidecar.Application`) is NOT added to the main `Cortex.Application` supervision tree. It is only started explicitly (via escript entry point or `Sidecar.Application.start/2` in tests). Sidecar GenServers use configurable names (default to module name, overridable in opts) so tests can start multiple instances.
- **Validation time:** ~5 minutes to verify the sidecar modules compile but don't auto-start with `mix phx.server`.

---

## Recommended API Surface

### Sidecar.Config

```elixir
@spec from_env() :: {:ok, Config.t()} | {:error, [String.t()]}
@spec from_env(map()) :: {:ok, Config.t()} | {:error, [String.t()]}
```

### Sidecar.Connection

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
@spec send_message(GenServer.server(), map()) :: :ok | {:error, term()}
@spec status(GenServer.server()) :: :connecting | :connected | :disconnected | :reconnecting
```

### Sidecar.State

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
@spec get_agent_id(GenServer.server()) :: String.t() | nil
@spec set_agent_id(GenServer.server(), String.t()) :: :ok
@spec get_status(GenServer.server()) :: atom()
@spec set_status(GenServer.server(), atom()) :: :ok
@spec get_roster(GenServer.server()) :: [map()]
@spec update_roster(GenServer.server(), [map()]) :: :ok
@spec push_message(GenServer.server(), map()) :: :ok
@spec pop_messages(GenServer.server()) :: [map()]
@spec get_current_task(GenServer.server()) :: map() | nil
@spec set_current_task(GenServer.server(), map() | nil) :: :ok
@spec get_config(GenServer.server()) :: Config.t()
```

### Sidecar.Connection.Transport (behaviour)

```elixir
@callback connect(String.t(), keyword()) :: {:ok, state} | {:error, term()}
@callback send_frame(state, term()) :: {:ok, state} | {:error, term()}
@callback close(state) :: :ok
```

### Dependencies on Phase 1 Modules

```elixir
# Shared protocol modules for message encoding
Gateway.Protocol.Messages.RegisterMessage.to_map/1
Gateway.Protocol.Messages.HeartbeatMessage.to_map/1
Gateway.Protocol.Messages.StatusUpdateMessage.to_map/1
Gateway.Protocol.Messages.TaskResultMessage.to_map/1

# For parsing inbound messages from gateway
Gateway.Protocol.Messages.RegisteredResponse.new/1
Gateway.Protocol.Messages.TaskRequestMessage.new/1
Gateway.Protocol.Messages.PeerRequestMessage.new/1
```

---

## Folder Structure

```
lib/
  cortex/
    sidecar/
      application.ex          # OTP Application (Sidecar Core Engineer)
      config.ex               # Config parsing + validation (Sidecar Core Engineer)
      connection.ex           # WebSocket client GenServer (Sidecar Core Engineer)
      connection/
        transport.ex           # Transport behaviour (Sidecar Core Engineer)
        mint_transport.ex      # Mint.WebSocket implementation (Sidecar Core Engineer)
        phoenix_protocol.ex    # Phoenix Channel client protocol (Sidecar Core Engineer)
      state.ex                # State manager GenServer (Sidecar Core Engineer)
      router.ex               # HTTP API (Sidecar HTTP API Engineer — NOT mine)

test/
  cortex/
    sidecar/
      config_test.exs          # Config unit tests (Sidecar Core Engineer)
      connection_test.exs      # Connection unit tests (Sidecar Core Engineer)
      state_test.exs           # State unit tests (Sidecar Core Engineer)
  support/
    sidecar/
      mock_transport.ex        # Mock Transport for tests (Sidecar Core Engineer)
```

Modules I create: `Cortex.Sidecar.Application`, `Cortex.Sidecar.Config`, `Cortex.Sidecar.Connection`, `Cortex.Sidecar.Connection.Transport`, `Cortex.Sidecar.Connection.MintTransport`, `Cortex.Sidecar.Connection.PhoenixProtocol`, `Cortex.Sidecar.State`
Modules I modify: None.
Modules I depend on: `Cortex.Gateway.Protocol`, `Cortex.Gateway.Protocol.Messages.*`

---

## Tighten the plan into 4-7 small tasks

### Task 1: Config module with env var parsing and validation

- **Outcome:** `Sidecar.Config` reads environment variables, validates required/optional fields, parses capabilities, applies defaults, and returns `{:ok, config}` or `{:error, reasons}`.
- **Files to create:** `lib/cortex/sidecar/config.ex`, `test/cortex/sidecar/config_test.exs`
- **Verification:**
  ```bash
  mix test test/cortex/sidecar/config_test.exs
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `feat(sidecar): add Config module with env var parsing and validation`

### Task 2: State manager GenServer

- **Outcome:** `Sidecar.State` GenServer with typed accessors for agent_id, connection status, roster, pending messages, current task, and config. Fully tested.
- **Files to create:** `lib/cortex/sidecar/state.ex`, `test/cortex/sidecar/state_test.exs`
- **Verification:**
  ```bash
  mix test test/cortex/sidecar/state_test.exs
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `feat(sidecar): add State manager GenServer for sidecar state`

### Task 3: Transport behaviour and Phoenix Channel client protocol

- **Outcome:** A `Transport` behaviour for WebSocket abstraction, a `MintTransport` implementation using Mint.WebSocket, and a `PhoenixProtocol` module that handles the Phoenix Channel wire format (join, phx_heartbeat, message envelope encoding/decoding). Add `mint_web_socket` dependency if needed.
- **Files to create:** `lib/cortex/sidecar/connection/transport.ex`, `lib/cortex/sidecar/connection/mint_transport.ex`, `lib/cortex/sidecar/connection/phoenix_protocol.ex`
- **Files to modify:** `mix.exs` (add `mint_web_socket` dep if not present)
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex/sidecar/
  ```
- **Suggested commit message:** `feat(sidecar): add Transport behaviour, MintTransport, and PhoenixProtocol`

### Task 4: Connection GenServer with registration, heartbeats, and reconnection

- **Outcome:** `Sidecar.Connection` GenServer connects to the gateway via the Transport behaviour, sends registration on connect, sends periodic heartbeats, handles inbound messages (registered, task_request, peer_request), auto-reconnects with exponential backoff, and exposes `send_message/2` and `status/1`. Fully tested with a mock transport.
- **Files to create:** `lib/cortex/sidecar/connection.ex`, `test/cortex/sidecar/connection_test.exs`, `test/support/sidecar/mock_transport.ex`
- **Verification:**
  ```bash
  mix test test/cortex/sidecar/connection_test.exs
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `feat(sidecar): add Connection GenServer with registration, heartbeats, and auto-reconnect`

### Task 5: Sidecar OTP Application and supervision tree

- **Outcome:** `Sidecar.Application` starts the supervision tree (State, then Connection) with `:rest_for_one` strategy. Reads config on startup, fails fast on invalid config. Placeholder child spec for the HTTP server.
- **Files to create:** `lib/cortex/sidecar/application.ex`
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex/sidecar/
  mix format --check-formatted
  mix credo --strict
  ```
- **Suggested commit message:** `feat(sidecar): add Sidecar.Application OTP supervision tree`

### Task 6: Full test suite pass and code quality

- **Outcome:** All sidecar core tests pass. Code formatted. Credo clean. No warnings.
- **Files to modify:** Any files from tasks 1-5 that need fixes.
- **Verification:**
  ```bash
  mix format
  mix compile --warnings-as-errors
  mix credo --strict
  mix test test/cortex/sidecar/
  ```
- **Suggested commit message:** `chore(sidecar): clean up formatting, credo warnings, and test suite`

---

## CLAUDE.md Contributions (do NOT write the file; propose content)

### From Sidecar Core Engineer

**Coding style rules:**
- Sidecar modules live under `lib/cortex/sidecar/` — keep them self-contained and importable for the escript build.
- Use a Transport behaviour (`Sidecar.Connection.Transport`) for WebSocket I/O — never call `Mint.WebSocket` directly from `Connection`.
- Config is read once at startup from env vars. No runtime config reload.
- All sidecar GenServers accept a `:name` option for testability (multiple instances in tests).

**Dev commands:**
```bash
# Run sidecar core tests
mix test test/cortex/sidecar/

# Run with verbose output
mix test test/cortex/sidecar/ --trace

# Check if sidecar modules compile cleanly
mix compile --warnings-as-errors
```

**Before you commit checklist (additions):**
- Ensure `Sidecar.Connection` never crashes from network errors — wrap all transport calls in try/rescue or match on error tuples.
- Ensure `Sidecar.Config` validates ALL fields — never let an invalid config reach the Connection.
- Ensure heartbeat timer is cancelled on disconnect and restarted on reconnect.
- No `IO.inspect` or `dbg()` in sidecar code.

**Guardrails:**
- `Sidecar.Application` is NOT added to `Cortex.Application`'s supervision tree. It is started separately (via escript or explicit `Application.start`).
- The sidecar depends on `Gateway.Protocol` modules for message encoding — if the protocol changes, the sidecar must be updated in lockstep.
- The sidecar speaks the Phoenix Channel wire protocol, not raw JSON. If the gateway changes its Channel serializer, the sidecar's `PhoenixProtocol` module must be updated.

---

## EXPLAIN.md Contributions (do NOT write the file; propose outline bullets)

**Flow / Architecture:**
- The sidecar is a lightweight OTP application that runs alongside an agent process (in the same container or machine).
- On startup, it reads configuration from environment variables (gateway URL, agent identity, auth token).
- It establishes a WebSocket connection to the Cortex gateway using `Mint.WebSocket`.
- The connection speaks the Phoenix Channel wire protocol: it joins the `"agent:lobby"` topic and sends/receives messages in the `[join_ref, ref, topic, event, payload]` envelope format.
- On successful connection, it sends a `register` message with the agent's name, role, capabilities, and auth token.
- The gateway responds with `registered` and an assigned `agent_id`, which the sidecar stores.
- Periodic heartbeats (default: every 15s) keep the agent's health status current in the gateway registry.
- Inbound messages (`task_request`, `peer_request`) are queued in the State GenServer for the HTTP API to serve to the agent.
- If the gateway disconnects, the sidecar automatically reconnects with exponential backoff (1s -> 30s cap) and re-registers.

**Key Engineering Decisions + Tradeoffs:**
- `Mint.WebSocket` over `:gun` — lower-level but idiomatic Elixir, full lifecycle control, no hidden processes.
- Transport behaviour for testability — small abstraction cost, large test speed and reliability gain.
- `:rest_for_one` supervision — Connection depends on State, so Connection restarts when State restarts. Avoids stale State references.
- New `agent_id` on reconnect — simple, no gateway changes needed, but peers see a brief identity change. Session resumption deferred to a future phase.

**Limits of MVP + Next Steps:**
- No config hot-reload — restart sidecar to change config.
- No outbound message queuing during disconnect — messages are dropped, caller gets `{:error, :not_connected}`.
- No session resumption — reconnect gets a new `agent_id`.
- Pending message queue is unbounded — could grow if agent never reads messages.
- Next: session resumption protocol, outbound message buffering, config reload via SIGHUP, queue size limits.

**How to Run Locally + How to Validate:**
- Start the Cortex gateway: `mix phx.server`
- Set env vars and start the sidecar (exact mechanism depends on Packaging Engineer's work):
  ```bash
  CORTEX_GATEWAY_URL=ws://localhost:4000/agent/websocket \
  CORTEX_AGENT_NAME=test-agent \
  CORTEX_AGENT_ROLE="Test agent" \
  CORTEX_AGENT_CAPABILITIES=testing,validation \
  CORTEX_AUTH_TOKEN=your-gateway-token \
  mix run -e "Cortex.Sidecar.Application.start(:normal, [])"
  ```
- Observe the agent appearing in the gateway registry (via LiveView dashboard or `Cortex.Gateway.Registry.list/0` in IEx).
- Kill the gateway (`Ctrl+C`), watch sidecar logs for reconnect backoff.
- Restart the gateway, watch sidecar reconnect and re-register.
- Run tests: `mix test test/cortex/sidecar/`

---

## READY FOR APPROVAL
