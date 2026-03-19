# Sidecar HTTP API Plan

## You are in PLAN MODE.

### Project
I want to build the **Cortex Sidecar HTTP API** — the local HTTP server that runs inside the sidecar process and exposes RESTful endpoints for agents to interact with the Cortex mesh.

**Goal:** build a **Plug-based HTTP API** in which agents call `localhost:9090` to discover peers, exchange messages, invoke other agents, publish/query knowledge, and report status — all bridged to the Cortex gateway via the sidecar's WebSocket connection.

### Role + Scope
- **Role:** Sidecar HTTP API Engineer
- **Scope:** I own the Plug router, all HTTP handler modules, JSON request/response formatting, error middleware, and handler-level unit tests. I do NOT own the WebSocket connection (`Sidecar.Connection`), state manager (`Sidecar.State`), sidecar configuration (`Sidecar.Config`), packaging, or integration tests.
- **File I will write:** `/docs/cluster-mode/phase-2-sidecar/plans/sidecar-http-api.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

1. **Health** — `GET /health` returns sidecar connectivity status (WebSocket connected, agent registered, uptime).
2. **Roster** — `GET /roster`, `GET /roster/:agent_id`, `GET /roster/capable/:capability` return cached mesh agent data from `Sidecar.State`.
3. **Messaging** — `GET /messages` returns pending inbound messages; `POST /messages/:agent_id` sends a directed message; `POST /broadcast` sends to all agents.
4. **Invocation** — `POST /ask/:agent_id` and `POST /ask/capable/:capability` perform synchronous agent-to-agent calls. These block until a response arrives via WebSocket or timeout expires.
5. **Knowledge** — `GET /knowledge?topic=X` queries the gossip knowledge store; `POST /knowledge` publishes a new entry.
6. **Status** — `POST /status` reports progress to Cortex; `GET /task` returns the current task assignment; `POST /task/result` submits a task result.
7. **Error format** — Every error response uses the uniform shape `{"error": "<message>", "code": "<CODE>"}` with an appropriate HTTP status code.

## Non-Functional Requirements

1. **Latency** — All non-blocking endpoints (health, roster, messages, knowledge queries, status, task) must respond in < 10 ms under normal load. The sidecar serves a single co-located agent, so contention is near-zero.
2. **Blocking invocation** — `/ask` endpoints block for up to the caller-specified `timeout_ms` (default 60 s, max 300 s). The HTTP server must not starve other endpoints while an `/ask` call is in flight.
3. **Localhost only** — The HTTP server binds to `127.0.0.1` by default. No authentication is required on the local API (the sidecar trusts the co-located agent).
4. **JSON only** — All request and response bodies are `application/json`. Non-JSON requests to endpoints that expect a body return 415.
5. **Graceful degradation** — If the WebSocket connection to Cortex is down, read-only endpoints (health, roster cache, messages, task) still return cached data with a `"connected": false` flag. Write endpoints (send message, ask, status, publish knowledge) return 503.

## Assumptions / System Model

1. The sidecar runs exactly one HTTP server on `CORTEX_SIDECAR_PORT` (default 9090).
2. `Sidecar.State` (built by the Sidecar Core Engineer) is a GenServer that:
   - Caches the mesh roster (list of `RegisteredAgent`-like maps).
   - Stores pending inbound messages (received via WebSocket `peer_message` events).
   - Tracks the current task assignment (received via WebSocket `task_request`).
   - Tracks connection status (`:connected | :disconnected | :reconnecting`).
   - Exposes functions: `get_roster/0`, `get_agent/1`, `get_capable/1`, `get_messages/0`, `ack_messages/1`, `get_task/0`, `get_connection_status/0`.
3. `Sidecar.Connection` (built by the Sidecar Core Engineer) is a GenServer that:
   - Manages the WebSocket connection to the Cortex gateway.
   - Exposes functions: `send_message/2` (send a protocol message), `send_peer_request/3` (send a peer_request and wait for response with timeout).
4. The router is mounted into the sidecar's supervision tree by `Sidecar.Application` (Sidecar Core Engineer wires this).
5. Bandit is used as the HTTP server (already available in the Elixir ecosystem; lightweight, modern, Plug-compatible).

## Data Model (as relevant to this role)

The HTTP API is stateless — it reads from and writes to `Sidecar.State` and `Sidecar.Connection`. The data shapes it serializes:

### Agent (roster entry)
```json
{
  "id": "uuid",
  "name": "security-reviewer",
  "role": "Reviews code for security vulnerabilities",
  "capabilities": ["security-review", "cve-lookup"],
  "status": "idle",
  "metadata": {},
  "load": {"active_tasks": 1, "queue_depth": 0}
}
```

### Message
```json
{
  "id": "msg-uuid",
  "from_agent": "agent-uuid",
  "content": "Found 3 issues in auth module",
  "timestamp": "2026-03-18T12:00:00Z"
}
```

### Knowledge Entry
```json
{
  "id": "entry-uuid",
  "topic": "findings",
  "content": "SQL injection in user_controller.ex line 42",
  "source": "security-reviewer",
  "confidence": 0.9,
  "timestamp": "2026-03-18T12:00:00Z"
}
```

### Invocation Result
```json
{
  "status": "completed",
  "result": "Review complete. Found 3 issues...",
  "duration_ms": 12000
}
```

### Error
```json
{
  "error": "agent not found",
  "code": "NOT_FOUND"
}
```

## APIs (as relevant to this role)

### `GET /health`
Returns sidecar health status.

**Response 200:**
```json
{
  "status": "healthy",
  "connected": true,
  "agent_id": "uuid",
  "uptime_ms": 45000
}
```

### `GET /roster`
List all registered agents in the mesh.

**Response 200:**
```json
{
  "agents": [
    {"id": "...", "name": "...", "role": "...", "capabilities": [...], "status": "idle", "load": {...}}
  ],
  "count": 5,
  "connected": true
}
```

### `GET /roster/:agent_id`
Get details for a specific agent.

**Response 200:** Single agent object.
**Response 404:** `{"error": "agent not found", "code": "NOT_FOUND"}`

### `GET /roster/capable/:capability`
Find agents advertising a capability.

**Response 200:**
```json
{
  "agents": [...],
  "count": 2,
  "capability": "security-review"
}
```

### `GET /messages`
Get pending messages for this agent.

**Response 200:**
```json
{
  "messages": [...],
  "count": 3
}
```

### `POST /messages/:agent_id`
Send a message to another agent.

**Request:**
```json
{
  "content": "Please review the auth module"
}
```

**Response 200:** `{"status": "sent", "message_id": "msg-uuid"}`
**Response 404:** `{"error": "target agent not found", "code": "NOT_FOUND"}`
**Response 503:** `{"error": "not connected to Cortex", "code": "DISCONNECTED"}`

### `POST /broadcast`
Broadcast a message to all agents.

**Request:**
```json
{
  "content": "Standup: I found 3 critical issues"
}
```

**Response 200:** `{"status": "broadcast", "recipients": 5}`
**Response 503:** `{"error": "not connected to Cortex", "code": "DISCONNECTED"}`

### `POST /ask/:agent_id`
Synchronous agent-to-agent invocation by ID.

**Request:**
```json
{
  "prompt": "Review this code for SQL injection...",
  "timeout_ms": 60000
}
```

**Response 200:**
```json
{
  "status": "completed",
  "result": "Found 2 SQL injection vulnerabilities...",
  "duration_ms": 8500
}
```

**Response 408:** `{"error": "invocation timed out", "code": "TIMEOUT"}`
**Response 404:** `{"error": "agent not found", "code": "NOT_FOUND"}`
**Response 503:** `{"error": "not connected to Cortex", "code": "DISCONNECTED"}`

### `POST /ask/capable/:capability`
Synchronous invocation by capability (Cortex picks the best agent).

Same request/response shape as `POST /ask/:agent_id`.

### `GET /knowledge`
Query the knowledge store. Accepts query parameter `topic`.

**Response 200:**
```json
{
  "entries": [...],
  "count": 7,
  "topic": "findings"
}
```

### `POST /knowledge`
Publish a knowledge entry.

**Request:**
```json
{
  "topic": "findings",
  "content": "Found SQL injection in user_controller.ex",
  "confidence": 0.9
}
```

**Response 201:** `{"status": "published", "entry_id": "entry-uuid"}`
**Response 503:** `{"error": "not connected to Cortex", "code": "DISCONNECTED"}`

### `POST /status`
Report agent progress to Cortex.

**Request:**
```json
{
  "status": "working",
  "detail": "Analyzing file 3/7",
  "progress": 0.43
}
```

**Response 200:** `{"status": "accepted"}`
**Response 503:** `{"error": "not connected to Cortex", "code": "DISCONNECTED"}`

### `GET /task`
Get current task assignment.

**Response 200:**
```json
{
  "task": {
    "task_id": "task-uuid",
    "prompt": "Review code for security issues...",
    "timeout_ms": 300000,
    "tools": ["read_file", "grep"],
    "context": {}
  }
}
```

**Response 200 (no task):** `{"task": null}`

### `POST /task/result`
Submit task result.

**Request:**
```json
{
  "task_id": "task-uuid",
  "status": "completed",
  "result": {
    "text": "Review complete. Found 3 issues...",
    "tokens": {"input": 1500, "output": 800},
    "duration_ms": 12000
  }
}
```

**Response 200:** `{"status": "accepted"}`
**Response 400:** `{"error": "no active task", "code": "NO_TASK"}`
**Response 503:** `{"error": "not connected to Cortex", "code": "DISCONNECTED"}`

## Architecture / Component Boundaries

```
lib/cortex/sidecar/
  router.ex              # Plug.Router — mounts all handler plugs
  handlers/
    health.ex            # GET /health
    roster.ex            # GET /roster, /roster/:id, /roster/capable/:cap
    messages.ex          # GET/POST /messages, POST /broadcast
    invoke.ex            # POST /ask/:id, /ask/capable/:cap
    knowledge.ex         # GET/POST /knowledge
    status.ex            # POST /status, GET /task, POST /task/result
```

### Router (`Cortex.Sidecar.Router`)
- `use Plug.Router`
- Plugs pipeline: `Plug.Logger`, `Plug.Parsers` (JSON), `Plug.Head`, `match`, `dispatch`
- Forwards `/health` to `Handlers.Health`
- Forwards `/roster` to `Handlers.Roster`
- Forwards `/messages` to `Handlers.Messages`
- Forwards `/broadcast` to `Handlers.Messages` (shared module)
- Forwards `/ask` to `Handlers.Invoke`
- Forwards `/knowledge` to `Handlers.Knowledge`
- Forwards `/status` to `Handlers.Status`
- Forwards `/task` to `Handlers.Status` (shared module)
- Catch-all returns 404 with standard error JSON

### Handler Pattern
Each handler module is a `Plug.Router` that matches its own sub-routes. Handlers:
1. Read state from `Sidecar.State` (via injected or application-configured server name).
2. For write operations, check connection status first — return 503 if disconnected.
3. For `/ask` endpoints, call `Sidecar.Connection.send_peer_request/3` which blocks.
4. Return JSON via a shared `json_response/3` helper.

### Dependency Direction
```
Router -> Handlers -> Sidecar.State (reads)
                   -> Sidecar.Connection (writes/invocations)
```

Handlers never access the WebSocket or gateway directly. They go through the `State` and `Connection` APIs.

## Correctness Invariants

1. **Every HTTP response is valid JSON** — even 404s and 500s. The catch-all route and a custom error handler ensure this.
2. **Write endpoints gate on connection status** — `POST /messages`, `POST /broadcast`, `POST /ask`, `POST /knowledge`, `POST /status`, `POST /task/result` all check `Sidecar.State.get_connection_status/0` and return 503 if not `:connected`.
3. **`/ask` timeout is bounded** — `timeout_ms` in the request body is clamped to `[1_000, 300_000]`. If omitted, defaults to 60_000.
4. **No state mutation in handlers** — Handlers are pure request/response translators. All state lives in `Sidecar.State` and `Sidecar.Connection`.
5. **Request body validation** — POST endpoints validate required fields and return 400 with specific error messages for missing/invalid fields. No silent defaults for required fields.
6. **Thread safety** — Bandit handles each request in its own process. GenServer calls to `State` and `Connection` are serialized by OTP. No shared mutable state outside GenServers.

## Tests

All tests use `async: true` (handlers are stateless; state is injected via GenServer names).

### `test/cortex/sidecar/router_test.exs`
- 404 on unknown routes returns JSON error
- Routes are correctly mounted (smoke test each endpoint returns non-404)

### `test/cortex/sidecar/handlers/health_test.exs`
- Returns healthy status with connection info
- Returns degraded status when disconnected

### `test/cortex/sidecar/handlers/roster_test.exs`
- Lists all agents from state
- Returns single agent by ID
- Returns 404 for unknown agent ID
- Filters agents by capability
- Returns empty list when no agents match capability

### `test/cortex/sidecar/handlers/messages_test.exs`
- Returns pending messages
- Sends message to agent (connected)
- Returns 503 when disconnected
- Returns 404 for unknown target agent
- Broadcast returns recipient count
- Validates request body (missing content)

### `test/cortex/sidecar/handlers/invoke_test.exs`
- Successful synchronous invocation returns result
- Timeout returns 408
- Unknown agent returns 404
- Disconnected returns 503
- Capability-based invocation routes correctly
- Validates request body (missing prompt)
- Timeout clamping (too large, too small, default)

### `test/cortex/sidecar/handlers/knowledge_test.exs`
- Queries entries by topic
- Returns all entries when no topic filter
- Publishes entry (connected)
- Returns 503 when disconnected
- Validates publish request body (missing topic, missing content)

### `test/cortex/sidecar/handlers/status_test.exs`
- Reports status successfully
- Returns 503 when disconnected
- Returns current task
- Returns null when no task
- Submits task result
- Returns 400 when no active task
- Validates status request body

### Test Strategy
Each handler test starts a mock `Sidecar.State` and `Sidecar.Connection` GenServer with a unique name, passes the name into the handler via `Plug.Conn` assigns or application config, and makes HTTP requests via `Plug.Test.conn/3`. No real WebSocket or Cortex gateway needed.

## Benchmarks + "Success"

### Benchmarks
- **Throughput:** Use `Benchee` to measure requests/second for each endpoint category (health, roster, messages, invoke with mock instant response).
- **Latency distribution:** p50, p95, p99 for non-blocking endpoints under 100 concurrent connections.

### Success Criteria
- Non-blocking endpoints: p99 < 5 ms with a single caller (the co-located agent).
- `/ask` endpoints: overhead < 50 ms beyond the actual peer response time.
- All handler tests pass.
- `mix credo --strict` clean.
- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.

## Engineering Decisions & Tradeoffs

### 1. Bandit vs Plug.Cowboy for the HTTP server
**Decision:** Use Bandit.
**Rationale:** Bandit is modern, pure-Elixir, and handles each connection in its own process (good for blocking `/ask` calls that tie up a connection for up to 5 minutes). Plug.Cowboy is battle-tested but Cowboy's pool model could exhaust workers during long-running `/ask` calls. Bandit's process-per-connection model avoids this.
**Tradeoff:** Bandit is newer and less battle-tested in production than Cowboy, but the sidecar serves a single agent (low traffic), so production hardening is less critical.

### 2. Handler modules as Plug.Router vs plain functions called from the main router
**Decision:** Each handler is its own `Plug.Router` module, forwarded from the main router.
**Rationale:** Keeps each handler self-contained with its own route matching. Easier to test in isolation (mount the handler directly in tests). Follows the same pattern Phoenix uses internally.
**Tradeoff:** Slightly more boilerplate than a flat router with plain function calls, but the modularity pays off in testability and readability.

### 3. Blocking `/ask` via GenServer.call with timeout vs async polling
**Decision:** Use `GenServer.call` with a timeout on `Sidecar.Connection.send_peer_request/3`. The HTTP connection blocks until the call returns.
**Rationale:** The agent calling `/ask` expects a synchronous response — it's being used as a tool. Polling adds complexity for no benefit since the agent can't do other work while waiting. Bandit's process-per-connection model means the blocked connection doesn't affect other requests.
**Tradeoff:** A blocked `/ask` ties up a Bandit process and a Connection caller slot. With a single agent, this is fine. If multiple concurrent `/ask` calls were needed, we'd need to revisit (but the spec says one agent per sidecar).

### 4. Connection status gating on write endpoints
**Decision:** All write endpoints (POST) check connection status and return 503 immediately if disconnected. Read endpoints return cached data with a `"connected": false` flag.
**Rationale:** An agent can still read cached roster/messages/task data while disconnected (useful for graceful degradation). But attempting to send messages or invoke agents while disconnected would silently fail, so we fail fast with a clear error.
**Tradeoff:** Some write operations (like knowledge publish) could theoretically be queued for when the connection recovers, but that adds complexity for an edge case. Fail-fast is simpler and more predictable.

## Risks & Mitigations

### 1. Sidecar.State / Sidecar.Connection API mismatch
**Risk:** The handler code assumes specific function signatures on `State` and `Connection` that the Sidecar Core Engineer may implement differently.
**Mitigation:** Define the expected API contract explicitly in this plan (see Assumptions section). Coordinate with Sidecar Core Engineer before implementation to agree on function names, arities, and return types. Use behaviour modules if needed.

### 2. `/ask` endpoint timeout leaking Bandit processes
**Risk:** If the Connection GenServer crashes or the WebSocket drops during an `/ask` call, the HTTP process could hang until the GenServer.call timeout fires.
**Mitigation:** The `GenServer.call` timeout matches the user-provided `timeout_ms`, which is clamped to 300 s max. If the Connection GenServer exits, the caller gets `{:EXIT, ...}` immediately. Add a `try/catch` around the call to translate crashes into 500 errors.

### 3. Bandit dependency not yet in mix.exs
**Risk:** Bandit is not currently a dependency. Adding it could conflict with the existing `plug_cowboy` dependency.
**Mitigation:** Bandit and Plug.Cowboy can coexist (they both implement the Plug adapter interface). The sidecar HTTP server is a separate endpoint from the Phoenix web server. If conflicts arise, fall back to starting Plug.Cowboy on a separate port.

### 4. Knowledge endpoint coupling to Gossip.KnowledgeStore
**Risk:** The knowledge endpoints need to bridge between the HTTP API and the Gossip.KnowledgeStore, but the sidecar doesn't run a local KnowledgeStore — knowledge operations go through the Cortex gateway.
**Mitigation:** Knowledge endpoints send `knowledge_query` and `knowledge_publish` messages over the WebSocket to Cortex, which interacts with the KnowledgeStore. The sidecar doesn't need a local KnowledgeStore process.

### 5. Handler test isolation
**Risk:** Tests that start mock GenServers with global names could conflict in parallel test runs.
**Mitigation:** Each test starts State and Connection mocks with unique names (e.g., `:"state_#{System.unique_integer()}"`) and passes them into the handler via conn assigns. All tests use `async: true`.

---

# Recommended API Surface

See the **APIs** section above for the complete specification of all 14 endpoints across 6 handler modules.

Summary of modules and their public functions:

| Module | Public Functions |
|--------|-----------------|
| `Sidecar.Router` | `init/1`, `call/2` (Plug callbacks) |
| `Handlers.Health` | `init/1`, `call/2` |
| `Handlers.Roster` | `init/1`, `call/2` |
| `Handlers.Messages` | `init/1`, `call/2` |
| `Handlers.Invoke` | `init/1`, `call/2` |
| `Handlers.Knowledge` | `init/1`, `call/2` |
| `Handlers.Status` | `init/1`, `call/2` |

Each handler module is a `Plug.Router` — public API is the standard Plug interface.

# Folder Structure

```
lib/cortex/sidecar/
  router.ex                          # Main Plug.Router (mounts handlers)
  handlers/
    health.ex                        # GET /health
    roster.ex                        # GET /roster, /roster/:id, /roster/capable/:cap
    messages.ex                      # GET /messages, POST /messages/:id, POST /broadcast
    invoke.ex                        # POST /ask/:id, POST /ask/capable/:cap
    knowledge.ex                     # GET /knowledge, POST /knowledge
    status.ex                        # POST /status, GET /task, POST /task/result

test/cortex/sidecar/
  router_test.exs                    # Router-level smoke tests
  handlers/
    health_test.exs
    roster_test.exs
    messages_test.exs
    invoke_test.exs
    knowledge_test.exs
    status_test.exs
```

Ownership: All files above are owned by the Sidecar HTTP API Engineer.

# Step-by-Step Task Plan (small commits)

### Task 1: Router scaffold + health handler
- Create `lib/cortex/sidecar/router.ex` with Plug pipeline and catch-all 404
- Create `lib/cortex/sidecar/handlers/health.ex` with `GET /health`
- Create `test/cortex/sidecar/router_test.exs` and `test/cortex/sidecar/handlers/health_test.exs`
- **Files:** `router.ex`, `handlers/health.ex`, `router_test.exs`, `handlers/health_test.exs`
- **Verify:** `mix test test/cortex/sidecar/router_test.exs test/cortex/sidecar/handlers/health_test.exs`
- **Commit:** `feat(sidecar): add Plug router scaffold and health endpoint`

### Task 2: Roster handler
- Create `lib/cortex/sidecar/handlers/roster.ex` with all three roster routes
- Create `test/cortex/sidecar/handlers/roster_test.exs`
- **Files:** `handlers/roster.ex`, `handlers/roster_test.exs`
- **Verify:** `mix test test/cortex/sidecar/handlers/roster_test.exs`
- **Commit:** `feat(sidecar): add roster handler for mesh agent discovery`

### Task 3: Messages handler
- Create `lib/cortex/sidecar/handlers/messages.ex` with GET messages, POST send, POST broadcast
- Create `test/cortex/sidecar/handlers/messages_test.exs`
- **Files:** `handlers/messages.ex`, `handlers/messages_test.exs`
- **Verify:** `mix test test/cortex/sidecar/handlers/messages_test.exs`
- **Commit:** `feat(sidecar): add messaging handler for agent-to-agent messages`

### Task 4: Invoke handler (blocking /ask)
- Create `lib/cortex/sidecar/handlers/invoke.ex` with both ask routes
- Create `test/cortex/sidecar/handlers/invoke_test.exs`
- **Files:** `handlers/invoke.ex`, `handlers/invoke_test.exs`
- **Verify:** `mix test test/cortex/sidecar/handlers/invoke_test.exs`
- **Commit:** `feat(sidecar): add invoke handler for synchronous agent-to-agent calls`

### Task 5: Knowledge + status handlers
- Create `lib/cortex/sidecar/handlers/knowledge.ex` with GET/POST knowledge
- Create `lib/cortex/sidecar/handlers/status.ex` with POST status, GET task, POST task/result
- Create `test/cortex/sidecar/handlers/knowledge_test.exs`
- Create `test/cortex/sidecar/handlers/status_test.exs`
- **Files:** `handlers/knowledge.ex`, `handlers/status.ex`, `handlers/knowledge_test.exs`, `handlers/status_test.exs`
- **Verify:** `mix test test/cortex/sidecar/handlers/knowledge_test.exs test/cortex/sidecar/handlers/status_test.exs`
- **Commit:** `feat(sidecar): add knowledge and status handlers`

### Task 6: Full suite verification + cleanup
- Run full test suite, credo, format check, compile warnings check
- Fix any issues found
- **Files:** All handler and test files (cleanup only)
- **Verify:** `mix format && mix compile --warnings-as-errors && mix credo --strict && mix test test/cortex/sidecar/`
- **Commit:** `chore(sidecar): polish HTTP API — format, credo, warnings`

# Benchmark Plan

**Tool:** Benchee (already in deps for `:dev`).

**File:** `bench/sidecar_http_bench.exs`

**Scenarios:**
1. `GET /health` — baseline latency (no GenServer calls)
2. `GET /roster` — GenServer read (cached state)
3. `POST /messages/:id` — GenServer write + WebSocket send
4. `POST /ask/:id` — blocking invocation with mock instant response (measures overhead)

**Success:**
- `GET /health` p99 < 1 ms
- `GET /roster` p99 < 5 ms
- `POST /messages` p99 < 10 ms
- `POST /ask` overhead (minus mock response delay) p99 < 50 ms

# CLAUDE.md Contributions (do NOT write the file; propose content)

## From Sidecar HTTP API Engineer

```
## Sidecar HTTP API
- Router: lib/cortex/sidecar/router.ex — Plug.Router mounting all handlers
- Handlers: lib/cortex/sidecar/handlers/ — one module per endpoint group
- All endpoints return JSON; errors use {"error": "...", "code": "..."} format
- /ask endpoints block until peer response or timeout (max 300s)
- Write endpoints return 503 when WebSocket is disconnected
- Tests use mock State/Connection GenServers with unique names (async: true)
```

# EXPLAIN.md Contributions (do NOT write the file; propose outline bullets)

- **Sidecar HTTP API** — the agent-facing interface
  - How the Plug router is structured (forwarding to handler sub-routers)
  - Request lifecycle: HTTP request -> handler -> State/Connection GenServer -> WebSocket -> Cortex
  - Blocking invocation model: how `/ask` uses GenServer.call with timeout
  - Error handling: uniform JSON errors, connection gating on writes
  - Why Bandit over Cowboy for the sidecar HTTP server
  - Testing strategy: mock GenServers, Plug.Test, async isolation

---

## READY FOR APPROVAL
