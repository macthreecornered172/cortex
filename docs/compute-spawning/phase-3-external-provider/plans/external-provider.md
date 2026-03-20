# External Provider Engineer — Phase 3 External Provider Plan

## You are in PLAN MODE.

### Project
I want to do a **Provider.External implementation for Cortex**.

**Goal:** build a **Provider.External module and PendingTasks registry** in which we **dispatch orchestration work to sidecar-connected agents via the Gateway and deliver results back to the orchestrator, enabling all three workflow modes (DAG, mesh, gossip) to run agents through the sidecar control plane instead of local Erlang ports**.

### Role + Scope
- **Role:** External Provider Engineer
- **Scope:** I own `Provider.External` (the Provider behaviour implementation that dispatches to sidecar agents) and `Provider.External.PendingTasks` (the ETS-backed registry that correlates task_id to waiting caller). I do NOT own the `route_task_result/2` wiring in `Gateway.Registry` (Task Routing Engineer), the `TaskPush` module for transport-specific message sending (Task Routing Engineer), or the WebSocket channel handler updates (Task Routing Engineer).
- **File you will write:** `docs/compute-spawning/phase-3-external-provider/plans/external-provider.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** Implement `Cortex.Provider.External` that satisfies the `Cortex.Provider` behaviour (`start/1`, `run/3`, `stop/1`).
- **FR2:** `run/3` dispatches a `TaskRequest` to a sidecar-connected agent found by name in `Gateway.Registry`, then blocks until a `TaskResult` arrives or timeout expires.
- **FR3:** Implement `Cortex.Provider.External.PendingTasks` as a GenServer that owns an ETS table mapping `task_id` to `{caller_pid, caller_ref, dispatch_time}`. Provides `register_task/3`, `resolve_task/2`, `cancel_task/1`, and `list_pending/0`.
- **FR4:** `resolve_task/2` sends the result to the blocked caller via `send(pid, {:task_result, ref, result})`, then deletes the ETS entry.
- **FR5:** `Provider.External.run/3` returns `{:ok, %TeamResult{}}` on success or `{:error, reason}` on failure/timeout, matching the synchronous contract of `Provider.CLI.run/3`.
- **FR6:** Emit telemetry events using existing helpers: `Cortex.Telemetry.emit_gateway_task_dispatched/1` on dispatch, `Cortex.Telemetry.emit_gateway_task_completed/1` on result or timeout.
- Tests required: unit tests for PendingTasks (register, resolve, cancel, list, concurrent access) and Provider.External (agent found, agent not found, timeout, result conversion).
- Metrics required: uses existing `[:cortex, :gateway, :task, :dispatched]` and `[:cortex, :gateway, :task, :completed]` telemetry events already defined in `Cortex.Telemetry`.

## Non-Functional Requirements
- Language/runtime: Elixir 1.16+, Erlang/OTP 26+
- Local dev: `mix test test/cortex/provider/external_test.exs test/cortex/provider/external/pending_tasks_test.exs`
- Observability: telemetry events via existing `Cortex.Telemetry` helpers; Prometheus counters and distributions already configured in `Cortex.Application`
- Safety: timeout on `run/3` prevents indefinite blocking; ETS cleanup on task cancel/timeout prevents leaks; monitor caller pid to auto-cancel if caller dies
- Documentation: `@moduledoc`, `@doc`, `@spec` on all public functions per project conventions
- Performance: ETS with `read_concurrency: true` for lock-free reads; no GenServer serialization on the hot path (resolve_task reads ETS directly)

---

## Assumptions / System Model
- Deployment environment: local development; Gateway.Registry and Gateway.Supervisor are running
- Failure modes:
  - **Agent not found:** `run/3` returns `{:error, :agent_not_found}` immediately
  - **Agent disconnects mid-task:** PendingTasks entry remains until timeout; caller gets `{:error, :timeout}`
  - **Caller dies while waiting:** PendingTasks monitors caller pid, removes entry on `:DOWN`
  - **PendingTasks process crashes:** supervised by Gateway.Supervisor, ETS table is lost, in-flight tasks fail with timeout on the caller side (acceptable for MVP)
  - **Gateway.Registry not running:** `start/1` returns `{:error, :registry_not_available}`
- Delivery guarantees: at-most-once delivery of TaskRequest to agent; no retry on push failure (caller gets `{:error, :push_failed}`)
- Multi-tenancy: none for MVP

---

## Data Model

### PendingTasks ETS Table

- **Table name:** `:cortex_pending_tasks`
- **Table type:** `:set` with `read_concurrency: true`
- **Key:** `task_id :: String.t()` (UUID v4)
- **Value:** `{caller_pid :: pid(), caller_ref :: reference(), dispatched_at :: integer(), agent_id :: String.t()}`
- **Validation:** task_id must be a non-empty string; caller_pid must be alive at registration time
- **Versioning:** N/A for MVP
- **Persistence:** in-memory only; ETS table owned by PendingTasks GenServer

### Provider.External Handle

- Returned by `start/1`, passed to `run/3` and `stop/1`
- Shape: `%{registry: GenServer.server(), timeout_ms: non_neg_integer()}`
- `registry` defaults to `Cortex.Gateway.Registry` (configurable for testing)
- `timeout_ms` defaults to 30 minutes (matches Provider.CLI default)

### TaskResult to TeamResult Conversion

Map from proto `TaskResult` fields (received as a map from `route_task_result/2`) to `TeamResult`:

| TaskResult field | TeamResult field | Conversion |
|---|---|---|
| `"status"` | `:status` | `"completed"` -> `:success`, `"failed"` -> `:error`, `"cancelled"` -> `:error` |
| `"result_text"` | `:result` | direct string copy |
| `"duration_ms"` | `:duration_ms` | direct integer copy |
| `"input_tokens"` | `:input_tokens` | direct integer copy |
| `"output_tokens"` | `:output_tokens` | direct integer copy |
| (not present) | `:cost_usd` | `nil` (sidecar doesn't track cost) |
| (not present) | `:session_id` | `nil` (no CLI session) |
| (not present) | `:cache_read_tokens` | `nil` |
| (not present) | `:cache_creation_tokens` | `nil` |
| (not present) | `:num_turns` | `nil` |

---

## APIs

### Provider.External — Provider Behaviour Implementation

```elixir
@spec start(config :: map() | keyword()) :: {:ok, handle()} | {:error, term()}
# Config keys:
#   :registry — GenServer.server(), default Gateway.Registry
#   :timeout_ms — integer, default 1_800_000 (30 min)
#   :pending_tasks — GenServer.server(), default PendingTasks (for test injection)
# Returns {:ok, %{registry: server, timeout_ms: ms, pending_tasks: server}}
# Returns {:error, :registry_not_available} if Registry is not running

@spec run(handle(), prompt :: String.t(), opts :: keyword()) ::
        {:ok, TeamResult.t()} | {:error, term()}
# Opts:
#   :team_name — required, string
#   :timeout_ms — optional, overrides handle default
# Errors:
#   {:error, :agent_not_found} — no agent with matching name in Registry
#   {:error, :push_failed} — could not send TaskRequest to agent
#   {:error, :timeout} — no TaskResult received within timeout

@spec stop(handle()) :: :ok
# No-op, stateless between runs (same as Provider.CLI)
```

### Provider.External.PendingTasks — Pending Task Registry

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
# Opts:
#   :name — GenServer name, default __MODULE__
#   :table_name — ETS table name, default :cortex_pending_tasks

@spec register_task(server, task_id :: String.t(), caller_pid :: pid(), caller_ref :: reference(), agent_id :: String.t()) :: :ok
# Inserts {task_id, {caller_pid, caller_ref, System.monotonic_time(:millisecond), agent_id}} into ETS
# Monitors caller_pid to auto-cancel on :DOWN

@spec resolve_task(server, task_id :: String.t(), result :: map()) :: :ok | {:error, :not_found}
# Looks up task_id in ETS, sends {:task_result, ref, result} to caller, deletes entry

@spec cancel_task(server, task_id :: String.t()) :: :ok
# Deletes ETS entry without sending result; demonitors caller pid

@spec list_pending(server) :: [%{task_id: String.t(), agent_id: String.t(), dispatched_at: integer()}]
# Returns all pending tasks (for debugging/monitoring)
```

---

## Architecture / Component Boundaries

### Components I Own

- **Provider.External** (`lib/cortex/provider/external.ex`) — implements Provider behaviour; the entry point for dispatching work to sidecar agents. Responsible for:
  - Agent lookup by name in Gateway.Registry
  - Task ID generation (UUID v4)
  - Registering pending tasks
  - Pushing TaskRequest via the agent's transport (delegates to TaskPush from the Task Routing Engineer)
  - Blocking on `receive` with timeout for TaskResult delivery
  - Converting TaskResult map to TeamResult struct
  - Emitting telemetry events

- **Provider.External.PendingTasks** (`lib/cortex/provider/external/pending_tasks.ex`) — GenServer owning an ETS table. Responsible for:
  - ETS table lifecycle (create on init, table dies with process)
  - Mapping task_id -> {caller_pid, caller_ref, dispatched_at, agent_id}
  - Monitoring caller pids to auto-cleanup on :DOWN
  - Exposing resolve_task/2 for the Task Routing Engineer to call from route_task_result/2

### Components I Depend On (Owned by Others)

- **Gateway.Registry** — agent lookup by name (`list/1`), push pid resolution (`get_push_pid/2`), status updates (`update_status/3`). Already exists and is fully functional.
- **TaskPush** (`lib/cortex/provider/external/task_push.ex`) — owned by Task Routing Engineer. Abstracts transport-specific message pushing (gRPC stream vs WebSocket channel). Provider.External calls `TaskPush.push/3`.
- **route_task_result/2 wiring** — owned by Task Routing Engineer. Currently a no-op in Registry; needs to call `PendingTasks.resolve_task/2`.

### Concurrency Model

- `run/3` is called from the orchestrator's spawned Task (one per team). Multiple `run/3` calls execute concurrently in separate BEAM processes.
- Each `run/3` call blocks its own process via `receive`; no worker pool needed.
- PendingTasks ETS reads are lock-free (`read_concurrency: true`). Writes go through the GenServer for monitor management.
- No backpressure needed at this layer — the orchestrator controls concurrency.

### Supervision

PendingTasks is added as a child of `Cortex.Gateway.Supervisor`, started after `Gateway.Registry`:

```
Cortex.Gateway.Supervisor
  ├── Cortex.Gateway.Registry
  ├── Cortex.Provider.External.PendingTasks   <-- new
  ├── Cortex.Gateway.Health
  └── GRPC.Server.Supervisor (when enabled)
```

---

## Correctness Invariants

1. **Every registered task is eventually resolved or cancelled.** A task registered in PendingTasks will either: (a) be resolved when a TaskResult arrives, (b) time out and be cancelled by the `run/3` caller, or (c) be auto-cancelled when the caller process dies.
2. **No orphaned ETS entries.** Caller pid monitoring ensures that if the caller crashes, the pending entry is cleaned up.
3. **TaskResult delivery is exactly-once to the caller.** `resolve_task/2` atomically deletes the ETS entry — a second `resolve_task/2` call for the same task_id returns `{:error, :not_found}`.
4. **Agent status is updated on dispatch.** `run/3` calls `Registry.update_status(agent_id, :working)` after successful push. (Reset to `:idle` is the agent's responsibility via heartbeat/status update.)
5. **Timeout never exceeds configured duration.** The `receive` block uses `after timeout_ms` — no infinite blocking.
6. **TeamResult always has `:team` and `:status` set.** The conversion function ensures these `@enforce_keys` are populated from the dispatch context and result map.

---

## Tests

### Unit Tests

**`test/cortex/provider/external/pending_tasks_test.exs`**
- `register_task/5` inserts entry retrievable by `list_pending/0`
- `resolve_task/3` delivers result to caller and removes entry
- `resolve_task/3` returns `{:error, :not_found}` for unknown task_id
- `resolve_task/3` returns `{:error, :not_found}` on double-resolve
- `cancel_task/2` removes entry without sending to caller
- Caller :DOWN auto-removes pending entry
- Concurrent register/resolve from multiple processes
- `list_pending/1` returns all pending tasks with correct fields

**`test/cortex/provider/external_test.exs`**
- `start/1` with default config returns handle with Registry reference
- `start/1` returns `{:error, :registry_not_available}` when Registry not running
- `run/3` with agent not found returns `{:error, :agent_not_found}`
- `run/3` dispatches task and returns TeamResult on successful result delivery
- `run/3` returns `{:error, :timeout}` when no result arrives within timeout
- `run/3` correctly converts TaskResult map to TeamResult struct (all field mappings)
- `run/3` emits telemetry events (task_dispatched, task_completed)
- `stop/1` returns `:ok`
- TeamResult status mapping: "completed" -> :success, "failed" -> :error, "cancelled" -> :error

### Integration Tests (coordinated with Task Routing Engineer)

**`test/cortex/provider/external/integration_test.exs`** (owned by Task Routing Engineer, but I design the contract)
- Start Gateway.Registry and PendingTasks
- Register a mock agent (fake gRPC stream pid)
- Call `Provider.External.run/3` in a Task
- Simulate sidecar sending TaskResult via `route_task_result/2`
- Assert `run/3` returns correct TeamResult

### Commands

```bash
mix test test/cortex/provider/external_test.exs
mix test test/cortex/provider/external/pending_tasks_test.exs
mix test test/cortex/provider/external/ --trace    # all external provider tests, verbose
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
```

---

## Benchmarks + "Success"

N/A for this role. Provider.External is an I/O-bound dispatcher — its performance is dominated by the agent's execution time, not the dispatch overhead. The dispatch path (ETS lookup + message send) is sub-microsecond and does not warrant benchmarking at this phase.

The meaningful performance metric is end-to-end task latency, which is the Task Routing Engineer's integration test territory.

---

## Engineering Decisions & Tradeoffs

### Decision 1: ETS Table Owned by GenServer vs Standalone ETS

- **Decision:** PendingTasks is a GenServer that creates and owns the ETS table in `init/1`.
- **Alternatives considered:** (a) Create ETS table in application startup and access it via a bare module with no GenServer. (b) Use a `Registry` (Elixir built-in) instead of raw ETS.
- **Why:** The GenServer provides a clean lifecycle (table dies with process, supervised restart creates a fresh table) and a natural place to handle `:DOWN` messages from monitored caller pids. A bare module + ETS would require a separate process to receive monitors. Elixir `Registry` adds overhead we don't need since our keys are string UUIDs, not PIDs.
- **Tradeoff acknowledged:** Writes go through the GenServer mailbox (serialized). This is acceptable because writes are infrequent (one register per task dispatch, one resolve per task completion) and reads use `read_concurrency: true` for the `list_pending/0` hot path.

### Decision 2: Blocking `receive` in `run/3` vs GenServer Call

- **Decision:** `run/3` uses a bare `receive` block with `after timeout_ms` to wait for the task result.
- **Alternatives considered:** (a) Make Provider.External a GenServer with a `handle_call` that defers reply via `{:noreply, state}` and replies when the result arrives. (b) Use `Task.async/await` with a sub-task.
- **Why:** The bare `receive` approach is the simplest and matches Provider.CLI's contract — `run/3` is called from the orchestrator's Task process and blocks that process until done. A GenServer would add unnecessary indirection and create a single-process bottleneck (only one task at a time). `Task.async/await` adds an extra process per dispatch for no benefit.
- **Tradeoff acknowledged:** The caller process's mailbox is used for result delivery, which means the caller must not `receive` other messages that could consume the task result message. This is safe because the orchestrator spawns a dedicated Task per team.

### Decision 3: Agent Lookup by Name, Not Capability

- **Decision:** `run/3` looks up the target agent by name using `Registry.list/1 |> Enum.find(& &1.name == team_name)`.
- **Alternatives considered:** Capability-based discovery via `Registry.list_by_capability/2`.
- **Why:** Specified in the kickoff. The orchestrator knows exactly which agent it spawned and what name it registered with. Capability-based discovery adds complexity (multiple matching agents, load balancing) that isn't needed in Phase 3.
- **Tradeoff acknowledged:** No load balancing or failover. If the named agent is busy or unhealthy, the task blocks until timeout. Capability-based routing is a natural Phase 4+ enhancement.

### Decision 4: Caller Pid Monitoring for Cleanup

- **Decision:** PendingTasks monitors the caller pid passed to `register_task/5`. On `:DOWN`, the pending entry is removed.
- **Alternatives considered:** (a) No monitoring — rely on timeout to clean up. (b) Periodic sweep of stale entries.
- **Why:** Without monitoring, if the caller crashes before timeout expires, the ETS entry leaks until the GenServer is restarted. Monitoring is cheap (one ref per pending task) and provides immediate cleanup.
- **Tradeoff acknowledged:** The GenServer must handle `:DOWN` messages, which adds slight complexity. However, the monitor map (`ref -> task_id`) is small (bounded by concurrent tasks) and lookup is O(1).

---

## Risks & Mitigations

### Risk 1: TaskPush Module Not Ready

- **Risk:** Provider.External depends on `TaskPush.push/3` (owned by Task Routing Engineer) to actually send the TaskRequest to the agent's transport. If TaskPush is not implemented or its interface changes, Provider.External cannot dispatch.
- **Impact:** Provider.External.run/3 cannot be tested end-to-end. Unit tests can mock TaskPush, but integration is blocked.
- **Mitigation:** Define the `TaskPush.push/3` contract explicitly in this plan (transport, pid, task_request -> :ok | {:error, reason}). Implement Provider.External with a configurable push function (default `TaskPush.push/3`, overridable in tests). Coordinate with Task Routing Engineer on interface before coding.
- **Validation time:** 5 minutes — agree on function signature in plan review.

### Risk 2: route_task_result/2 Not Wired

- **Risk:** `Gateway.Registry.route_task_result/2` is currently a no-op. Until the Task Routing Engineer wires it to call `PendingTasks.resolve_task/2`, results will never be delivered to waiting callers.
- **Impact:** `run/3` will always timeout in integration tests. Unit tests unaffected (they simulate result delivery directly).
- **Mitigation:** PendingTasks.resolve_task/2 is a standalone function. Provider.External unit tests can call it directly to simulate result delivery. Integration testing depends on the Task Routing Engineer completing their work.
- **Validation time:** 10 minutes — write a unit test that registers a task, then calls resolve_task directly, and verify the caller receives the result.

### Risk 3: ETS Table Name Collision

- **Risk:** The ETS table name `:cortex_pending_tasks` could collide with another table in the system, or in test isolation.
- **Impact:** `start_link/1` fails with `{:error, :already_exists}`.
- **Mitigation:** Make the table name configurable via `start_link(table_name: :my_test_table)`. Use unique names in async tests. Default name is distinctive enough for production.
- **Validation time:** 2 minutes — start two PendingTasks with different names in a test.

### Risk 4: Message Format Mismatch Between GrpcServer and PendingTasks

- **Risk:** The `GrpcServer.handle_task_result/2` calls `Registry.route_task_result/2` with a specific map format (keys: `"status"`, `"result_text"`, `"duration_ms"`, `"input_tokens"`, `"output_tokens"`). If `PendingTasks.resolve_task/2` expects a different format, the conversion in Provider.External will fail.
- **Impact:** Successful task results are silently lost or malformed.
- **Mitigation:** Document the exact map format that flows through `resolve_task/2` (it is the map from `GrpcServer`, not a proto struct). Write explicit conversion tests in `external_test.exs` for each field. The `handle_task_result` code in `grpc_server.ex:215-221` already shows the exact map shape.
- **Validation time:** 5 minutes — verify map keys in grpc_server.ex match conversion code.

---

## Recommended API Surface

### 1. `Cortex.Provider.External` (2 files: module + test)

| Function | Arity | Spec | Behaviour |
|---|---|---|---|
| `start/1` | 1 | `(config) :: {:ok, handle} \| {:error, term}` | `@impl Provider` |
| `run/3` | 3 | `(handle, prompt, opts) :: {:ok, TeamResult.t} \| {:error, term}` | `@impl Provider` |
| `stop/1` | 1 | `(handle) :: :ok` | `@impl Provider` |

### 2. `Cortex.Provider.External.PendingTasks` (2 files: module + test)

| Function | Arity | Spec |
|---|---|---|
| `start_link/1` | 1 | `(keyword) :: GenServer.on_start` |
| `register_task/5` | 5 | `(server, task_id, caller_pid, caller_ref, agent_id) :: :ok` |
| `resolve_task/3` | 3 | `(server, task_id, result) :: :ok \| {:error, :not_found}` |
| `cancel_task/2` | 2 | `(server, task_id) :: :ok` |
| `list_pending/1` | 1 | `(server) :: [map]` |

---

## Folder Structure

```
lib/cortex/provider/
  external.ex                          # Provider.External — behaviour implementation
  external/
    pending_tasks.ex                   # PendingTasks — ETS-backed GenServer

test/cortex/provider/
  external_test.exs                    # Provider.External unit tests
  external/
    pending_tasks_test.exs             # PendingTasks unit tests
```

Existing files that will be modified (by the Task Routing Engineer, not by me):
- `lib/cortex/gateway/supervisor.ex` — add PendingTasks as a child
- `lib/cortex/gateway/registry.ex` — wire route_task_result/2
- `lib/cortex/provider/external/task_push.ex` — new module for transport pushing

---

## Step-by-Step Task Plan (Small Commits)

---

# Tighten the plan into 4–7 small tasks

### Task 1: PendingTasks GenServer + ETS Table

- **Outcome:** A working `PendingTasks` GenServer that creates an ETS table, supports register/resolve/cancel/list, monitors caller pids, and auto-cleans on `:DOWN`.
- **Files to create:**
  - `lib/cortex/provider/external/pending_tasks.ex`
  - `test/cortex/provider/external/pending_tasks_test.exs`
- **Exact verification commands:**
  ```bash
  mix test test/cortex/provider/external/pending_tasks_test.exs
  mix compile --warnings-as-errors
  mix format --check-formatted
  mix credo --strict
  ```
- **Suggested commit message:** `feat(provider): add PendingTasks ETS registry for external task tracking`

### Task 2: Provider.External — start/1 and stop/1

- **Outcome:** Provider.External module with `@behaviour Cortex.Provider`, `start/1` that validates Gateway.Registry is running and returns a handle, and `stop/1` that returns `:ok`.
- **Files to create:**
  - `lib/cortex/provider/external.ex` (start/1, stop/1 only)
  - `test/cortex/provider/external_test.exs` (start/stop tests only)
- **Exact verification commands:**
  ```bash
  mix test test/cortex/provider/external_test.exs
  mix compile --warnings-as-errors
  mix format --check-formatted
  mix credo --strict
  ```
- **Suggested commit message:** `feat(provider): add Provider.External start/stop lifecycle`

### Task 3: Provider.External — run/3 Core Dispatch

- **Outcome:** `run/3` implements the full dispatch flow: generate task_id, find agent by name in Registry, register pending task, push TaskRequest (via a configurable push function to allow test injection), update agent status, block on receive with timeout, convert result to TeamResult, emit telemetry.
- **Files to modify:**
  - `lib/cortex/provider/external.ex` — add `run/3` implementation
  - `test/cortex/provider/external_test.exs` — add run/3 tests (mock push, simulate resolve)
- **Exact verification commands:**
  ```bash
  mix test test/cortex/provider/external_test.exs
  mix compile --warnings-as-errors
  mix format --check-formatted
  mix credo --strict
  ```
- **Suggested commit message:** `feat(provider): implement Provider.External.run/3 dispatch and result conversion`

### Task 4: TaskResult to TeamResult Conversion + Edge Cases

- **Outcome:** Thorough conversion from the `route_task_result/2` map format to `TeamResult`. Cover edge cases: missing fields, unknown status strings, nil values. Add tests for timeout path, agent-not-found path, push-failed path.
- **Files to modify:**
  - `lib/cortex/provider/external.ex` — refine conversion function
  - `test/cortex/provider/external_test.exs` — conversion edge case tests
- **Exact verification commands:**
  ```bash
  mix test test/cortex/provider/external_test.exs --trace
  mix compile --warnings-as-errors
  mix credo --strict
  ```
- **Suggested commit message:** `feat(provider): complete TaskResult-to-TeamResult conversion with edge cases`

### Task 5: Wire PendingTasks into Gateway.Supervisor

- **Outcome:** PendingTasks is started as a child of `Gateway.Supervisor`, after `Gateway.Registry` and before `Gateway.Health`. Provider.External defaults to the supervised instance.
- **Files to modify:**
  - `lib/cortex/gateway/supervisor.ex` — add PendingTasks child
- **Exact verification commands:**
  ```bash
  mix test
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `feat(gateway): add PendingTasks to Gateway.Supervisor tree`

---

## CLAUDE.md contributions (do NOT write the file; propose content)

### From External Provider Engineer

**Coding style rules:**
- Provider.External follows the same patterns as Provider.CLI — stateless handle, synchronous `run/3` contract
- PendingTasks API uses explicit `server` argument (not default module name) to support test isolation
- All ETS operations go through PendingTasks public functions — never read the table directly

**Dev commands:**
```bash
mix test test/cortex/provider/external_test.exs          # Provider.External tests
mix test test/cortex/provider/external/pending_tasks_test.exs  # PendingTasks tests
mix test test/cortex/provider/external/ --trace           # all, verbose
```

**Before you commit checklist:**
1. `mix format`
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix test test/cortex/provider/external/` — all pass
5. No IO.inspect or dbg() left in code
6. Verify PendingTasks table name doesn't collide in async tests

**Guardrails:**
- Provider.External.run/3 MUST always have a timeout — never use `:infinity`
- PendingTasks.resolve_task/2 MUST delete the ETS entry atomically — no window for double-delivery
- Never bypass PendingTasks to read the ETS table directly (breaks encapsulation and testability)

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture Explanation
- Provider.External is the bridge between the orchestration engine and sidecar-connected agents
- Dispatch flow: run/3 -> find agent by name -> register pending task -> push TaskRequest -> block on receive -> convert TaskResult -> return TeamResult
- PendingTasks is the correlation layer: maps task_id to the waiting caller process
- Result delivery: GrpcServer receives TaskResult -> route_task_result/2 -> PendingTasks.resolve_task/2 -> send to caller

### Key Engineering Decisions + Tradeoffs
- ETS with GenServer wrapper chosen over bare ETS (lifecycle management, pid monitoring) and over pure GenServer (read concurrency)
- Blocking receive chosen over GenServer call (simplicity, matches CLI contract, no single-process bottleneck)
- Agent lookup by name, not capability (phase 3 scope; capability routing is Phase 4+)

### Limits of MVP + Next Steps
- No retry on push failure — caller gets an error immediately
- No capability-based discovery or load balancing
- No streaming support (Provider.External does not implement `stream/3`)
- Agent disconnect mid-task results in timeout, not immediate failure notification
- Next: capability-based routing, streaming result delivery, agent health-aware dispatch

### How to Run Locally + How to Validate
- Requires Gateway.Supervisor running (default in `mix phx.server`)
- Register a sidecar agent via gRPC or WebSocket
- Configure a team with `provider: external` in YAML
- Run orchestration — Provider.External dispatches to the registered agent
- Validate: `mix test test/cortex/provider/external/ --trace`

---

## READY FOR APPROVAL
