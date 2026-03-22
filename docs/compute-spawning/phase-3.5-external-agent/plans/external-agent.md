# ExternalAgent GenServer Plan

## You are in PLAN MODE.

### Project
I want to build an **ExternalAgent GenServer** that bridges the Cortex spawner/control plane to sidecar-connected agents.

**Goal:** build an **ExternalAgent GenServer + DynamicSupervisor** in which we **own the Elixir-side relationship with each sidecar-connected agent, provide a run interface for the executor, and monitor sidecar health via Gateway PubSub events**.

### Role + Scope
- **Role:** ExternalAgent Engineer
- **Scope:** ExternalAgent GenServer (`lib/cortex/agent/external_agent.ex`), ExternalSupervisor DynamicSupervisor (`lib/cortex/agent/external_supervisor.ex`), and their tests. I do NOT own executor integration (that is the Executor Integration Engineer's scope), YAML config changes, or sidecar deployment.
- **File I will write:** `docs/compute-spawning/phase-3.5-external-agent/plans/external-agent.md`
- **No-touch zones:** executor.ex, application.ex, provider/external.ex, gateway/registry.ex, YAML config, sidecar code.

---

## Functional Requirements
- **FR1:** `ExternalAgent.start_link(opts)` starts a GenServer that confirms a sidecar with a matching `:name` is registered in `Gateway.Registry`, stores its `RegisteredAgent` data, subscribes to `Cortex.Events` PubSub, and returns `{:ok, pid}` or `{:stop, :agent_not_found}`.
- **FR2:** `ExternalAgent.run(server, prompt, opts)` is a `GenServer.call` that delegates to `Provider.External.start/1` then `Provider.External.run/3` using the stored agent's registry/transport info, blocks until the result arrives, and returns `{:ok, TeamResult.t()} | {:error, term()}`.
- **FR3:** `ExternalAgent.get_state(server)` returns the current internal state (agent info, status, health flag) for observability.
- **FR4:** `ExternalAgent.stop(server)` gracefully shuts down the GenServer, cleaning up PubSub subscription.
- **FR5:** The GenServer handles PubSub events: `:agent_status_changed` updates local status cache, `:agent_unregistered` (with matching agent_id) marks the agent unhealthy, `:agent_registered` (with matching name) re-acquires connection info for reconnect scenarios.
- **FR6:** `ExternalSupervisor` is a `DynamicSupervisor` that provides `start_agent/1`, `stop_agent/1`, and `list_agents/0`.
- **FR7:** `run/3` on an unhealthy agent returns `{:error, :agent_unhealthy}` immediately without attempting dispatch.
- **Tests required:** Unit tests for ExternalAgent GenServer (init success/failure, run delegation, PubSub event handling, unhealthy rejection) and ExternalSupervisor (start/stop/list).

## Non-Functional Requirements
- Language/runtime: Elixir 1.16+, Erlang/OTP 26+
- Local dev: `mix test test/cortex/agent/external_agent_test.exs`
- Observability: Telemetry events via `Cortex.Telemetry` for agent lifecycle (started, stopped, unhealthy)
- Safety: `run/3` rejects dispatch to unhealthy agents; GenServer.call timeout matches the task timeout to avoid caller hanging
- Documentation: `@moduledoc`, `@doc`, `@spec` on all public functions per project conventions
- Performance: N/A -- GenServer.call overhead is negligible relative to sidecar task execution time

---

## Assumptions / System Model
- **Deployment environment:** Single BEAM node (local dev); distributed node support is future work.
- **Failure modes:**
  - Sidecar disconnects mid-task: Provider.External's receive timeout fires, ExternalAgent receives `:agent_unregistered` PubSub event and marks unhealthy.
  - Gateway.Registry not running at start: `start_link` returns `{:stop, :registry_not_available}`.
  - Sidecar not yet registered: `start_link` returns `{:stop, :agent_not_found}`.
  - Sidecar reconnects after disconnect: `:agent_registered` PubSub event triggers re-acquisition of connection info, clearing unhealthy flag.
- **Delivery guarantees:** At-most-once for task dispatch (Provider.External handles retry/timeout semantics).
- **Multi-tenancy:** None for MVP.

---

## Data Model

### ExternalAgent State (internal GenServer state)

```elixir
%{
  name: String.t(),                    # agent name (matches sidecar registered name)
  agent_id: String.t(),                # UUID from Gateway.Registry RegisteredAgent
  registry: GenServer.server(),        # Gateway.Registry server ref
  timeout_ms: non_neg_integer(),       # default task timeout
  status: :healthy | :unhealthy,       # local health assessment
  agent_info: RegisteredAgent.t(),     # cached RegisteredAgent struct
  pending_tasks: GenServer.server(),   # PendingTasks server ref
  push_fn: function()                  # push function (injectable for tests)
}
```

- **Validation rules:** `:name` must be a non-empty binary. `:registry` must be a running process. `:timeout_ms` must be a positive integer.
- **Versioning:** No persistence; state is purely in-memory. On GenServer restart, re-queries Gateway.Registry.
- **Persistence:** None -- ExternalAgent is ephemeral per-run state.

---

## APIs

### ExternalAgent Client API

#### `start_link(opts)`
- **opts:** `[name: string, registry: server, timeout_ms: integer, pending_tasks: server, push_fn: fun]`
- **Behavior:** Queries `Gateway.Registry.list(registry)`, finds agent where `agent.name == opts[:name]`. If found, stores agent info and subscribes to `Cortex.Events`. If not found, returns `{:stop, :agent_not_found}`.
- **Returns:** `{:ok, pid}` | `{:stop, reason}`
- **Error cases:** `:agent_not_found`, `:registry_not_available`

#### `run(server, prompt, opts)`
- **GenServer.call** with timeout = `opts[:timeout_ms] || state.timeout_ms + 5_000` (extra 5s buffer so Provider.External's internal timeout fires first).
- **Behavior:** If `state.status == :unhealthy`, returns `{:error, :agent_unhealthy}`. Otherwise builds a Provider.External handle from state, calls `Provider.External.run(handle, prompt, run_opts)`, returns the result.
- **opts:** `[timeout_ms: integer]` (optional override)
- **Returns:** `{:ok, TeamResult.t()}` | `{:error, :agent_unhealthy | :agent_not_found | :push_failed | :timeout}`

#### `get_state(server)`
- **GenServer.call**
- **Returns:** `{:ok, map}` with keys `:name`, `:agent_id`, `:status`, `:agent_info`

#### `stop(server)`
- **Calls** `GenServer.stop(server, :normal)`
- **Returns:** `:ok`

### ExternalSupervisor API

#### `start_agent(opts)`
- Starts an ExternalAgent child under the DynamicSupervisor.
- **Returns:** `{:ok, pid}` | `{:error, term}`

#### `stop_agent(name)`
- Finds the ExternalAgent by name via `Cortex.Agent.Registry` (registers via `via_tuple` on agent name), terminates it.
- **Returns:** `:ok` | `{:error, :not_found}`

#### `find_agent(name)`
- Looks up a running ExternalAgent by name via `Cortex.Agent.Registry.lookup(name)`.
- **Returns:** `{:ok, pid}` | `:not_found`

#### `list_agents()`
- Returns all running ExternalAgent children as `[{name, pid}]`.
- **Returns:** `[{String.t(), pid()}]`

---

## Architecture / Component Boundaries

### Components I Touch

- **ExternalAgent GenServer** (`lib/cortex/agent/external_agent.ex`): Owns one sidecar relationship. Delegates work dispatch to Provider.External. Subscribes to Cortex.Events PubSub for sidecar health monitoring.
- **ExternalSupervisor** (`lib/cortex/agent/external_supervisor.ex`): DynamicSupervisor managing ExternalAgent processes. Uses `:one_for_one` strategy with `:temporary` restart (orchestration layer handles retries, not the supervisor).

### Components I Consume (read-only)

- **Gateway.Registry** -- query for agent by name, get push pid
- **Provider.External** -- `start/1`, `run/3`, `stop/1` for task dispatch
- **Provider.External.PendingTasks** -- passed through to Provider.External handle
- **Cortex.Events** -- subscribe for PubSub broadcasts
- **Cortex.Agent.Registry** -- Elixir Registry for ExternalAgent process lookup by name
- **Cortex.Telemetry** -- emit lifecycle events

### How Config Changes Propagate

ExternalAgent does not read YAML config. It receives its config as `opts` to `start_link`. The Executor Integration Engineer's scope covers reading YAML config and passing appropriate opts.

### Concurrency Model

- One GenServer per external agent. `run/3` is a blocking `GenServer.call` -- only one task at a time per ExternalAgent (matches current Provider.External semantics).
- PubSub events are processed asynchronously via `handle_info`.

### Backpressure

- Single-task-at-a-time per GenServer provides natural backpressure. If the executor needs to dispatch to the same agent concurrently, it would need multiple ExternalAgent instances (out of scope for this phase).

---

## Correctness Invariants

1. **Init confirms sidecar existence:** `start_link` with a name that has no matching agent in Gateway.Registry returns `{:stop, :agent_not_found}` -- never starts a GenServer with no backing sidecar.
2. **Unhealthy agents reject work:** `run/3` on an agent with `status: :unhealthy` returns `{:error, :agent_unhealthy}` without calling Provider.External.
3. **PubSub disconnect marks unhealthy:** When an `:agent_unregistered` event arrives for the agent's ID, status transitions to `:unhealthy`.
4. **PubSub reconnect restores healthy:** When an `:agent_registered` event arrives with a matching name, the GenServer re-queries Gateway.Registry, updates `agent_id` and `agent_info`, and restores `status: :healthy`.
5. **GenServer.call timeout exceeds Provider.External timeout:** The call timeout is always `provider_timeout + 5_000ms` to ensure Provider.External's receive timeout fires first, giving a clean `{:error, :timeout}` rather than a GenServer timeout crash.
6. **Supervisor uses `:temporary` restart:** Failed ExternalAgents are not auto-restarted. The orchestration layer decides whether to retry.
7. **Provider.External handle is built fresh per run:** No stale handle state -- each `run/3` call constructs a Provider.External handle from current GenServer state.

---

## Tests

### Unit Tests

**`test/cortex/agent/external_agent_test.exs`:**
- `start_link/1` with a registered agent succeeds, state is `:healthy`
- `start_link/1` with no matching agent returns `{:error, :agent_not_found}` (via start_link wrapper catching `:stop`)
- `start_link/1` with dead registry returns `{:error, :registry_not_available}`
- `get_state/1` returns correct name, agent_id, status
- `run/3` delegates to Provider.External with correct handle and opts (inject `:push_fn` that captures args and simulates result delivery)
- `run/3` on unhealthy agent returns `{:error, :agent_unhealthy}` without dispatch
- `run/3` with timeout returns `{:error, :timeout}`
- PubSub `:agent_unregistered` event for matching agent_id transitions to `:unhealthy`
- PubSub `:agent_unregistered` event for non-matching agent_id is ignored
- PubSub `:agent_status_changed` event updates cached status
- PubSub `:agent_registered` event with matching name re-acquires agent info and restores `:healthy`
- PubSub `:agent_registered` event with non-matching name is ignored

**`test/cortex/agent/external_supervisor_test.exs`:**
- `start_agent/1` starts an ExternalAgent and returns `{:ok, pid}`
- `find_agent/1` returns `{:ok, pid}` for a running agent
- `find_agent/1` returns `:not_found` for an unknown name
- `stop_agent/1` stops a running agent
- `stop_agent/1` with unknown name returns `{:error, :not_found}`
- `list_agents/0` returns all running agents
- Stopped agents no longer appear in `list_agents/0` or `find_agent/1`

### Commands

```bash
mix test test/cortex/agent/external_agent_test.exs
mix test test/cortex/agent/external_supervisor_test.exs
mix test test/cortex/agent/external_agent_test.exs test/cortex/agent/external_supervisor_test.exs --trace
```

---

## Benchmarks + "Success"

N/A -- ExternalAgent is a thin GenServer wrapper around Provider.External. The critical-path performance is in Provider.External's dispatch and the sidecar's task execution, both of which are already benchmarked. GenServer.call overhead (<1us) is not worth benchmarking.

Success criteria for this phase:
- All unit tests pass
- ExternalAgent correctly wraps Provider.External lifecycle
- PubSub health monitoring works (disconnect marks unhealthy, reconnect restores)
- ExternalSupervisor manages agent lifecycle under DynamicSupervisor

---

## Engineering Decisions & Tradeoffs

### Decision 1: GenServer.call for `run/3` (synchronous blocking)

- **Decision:** `run/3` is a synchronous `GenServer.call` that blocks the caller until Provider.External returns.
- **Alternatives considered:**
  - **GenServer.cast + callback:** Agent processes the task asynchronously and calls back. More complex; requires the caller to manage a receive loop or callback.
  - **Task.async wrapper:** Start a Task inside the GenServer for the Provider.External call. Adds a process layer without benefit since Provider.External already blocks internally.
- **Why:** Matches Provider.CLI's synchronous contract. The executor already expects `provider_mod.run/3` to block and return `{:ok, TeamResult.t()}`. GenServer.call preserves this contract naturally.
- **Tradeoff acknowledged:** Only one task at a time per ExternalAgent GenServer. Concurrent dispatch to the same sidecar requires multiple ExternalAgent instances. This is acceptable for MVP and mirrors the local Agent.Server pattern.

### Decision 2: Register ExternalAgent in `Cortex.Agent.Registry` by name (not UUID)

- **Decision:** ExternalAgent registers in the existing `Cortex.Agent.Registry` Elixir Registry using the agent's string name as the key, via `Cortex.Agent.Registry.via_tuple(name)`.
- **Alternatives considered:**
  - **Separate Registry module:** Create `Cortex.Agent.ExternalRegistry` with its own Elixir Registry. Cleaner namespace separation but adds unnecessary module proliferation.
  - **ETS lookup table:** Manual ETS for name-to-pid mapping. More work, no benefit over Registry.
- **Why:** `Cortex.Agent.Registry` already provides `via_tuple`, `lookup`, and `all` with automatic cleanup on process death. Using it avoids reinventing process registration. The key namespace (agent names vs UUIDs) doesn't collide because local Agent.Server uses UUIDs and ExternalAgent uses string names.
- **Tradeoff acknowledged:** Sharing the Registry means `Cortex.Agent.Registry.all/0` returns both local and external agents mixed together. If this becomes a problem, a prefix convention or separate Registry can be introduced later.

### Decision 3: Build Provider.External handle fresh per `run/3` call

- **Decision:** Each `run/3` call constructs a new Provider.External handle map from current GenServer state rather than caching a handle at init time.
- **Alternatives considered:**
  - **Cache handle at init:** Build the Provider.External handle once in `init/1` and reuse it. Slightly faster but the handle could become stale if the agent reconnects with a different transport/pid.
- **Why:** Provider.External's handle is a plain map with no process state. Building it is trivially cheap. Building fresh ensures the handle always reflects the latest agent info (important after reconnect events update `agent_info`).
- **Tradeoff acknowledged:** Tiny per-call overhead of map construction (~microseconds). Negligible compared to the 30-minute task timeout.

### Decision 4: Use `Cortex.Events` PubSub for health monitoring (not Process.monitor)

- **Decision:** ExternalAgent subscribes to `Cortex.Events` PubSub and reacts to `:agent_unregistered` / `:agent_registered` / `:agent_status_changed` events rather than directly monitoring the sidecar's transport pid.
- **Alternatives considered:**
  - **Direct Process.monitor on transport pid:** Monitor the sidecar's `channel_pid` or `stream_pid` directly. Faster notification but requires knowing the pid and re-monitoring on reconnect.
- **Why:** Gateway.Registry already monitors transport pids and broadcasts events when agents disconnect. Subscribing to PubSub is simpler, doesn't duplicate monitoring logic, and automatically handles the reconnect case (new `:agent_registered` event). It also means ExternalAgent doesn't need to reach into RegisteredAgent's internal transport pids for monitoring purposes.
- **Tradeoff acknowledged:** Slightly higher latency for disconnect detection (PubSub broadcast vs direct :DOWN message). The difference is sub-millisecond and irrelevant since Provider.External has its own timeout as a backstop.

---

## Risks & Mitigations

### Risk 1: Gateway.Registry PubSub events don't fire or have unexpected format

- **Risk:** The `safe_broadcast` calls in Gateway.Registry might not produce the exact event shape ExternalAgent expects, or the PubSub might not be started in test.
- **Impact:** ExternalAgent never detects sidecar disconnect/reconnect; stays stale.
- **Mitigation:** Write a test that starts Gateway.Registry, registers an agent, unregisters it, and verifies ExternalAgent receives the event and transitions to unhealthy. Read Gateway.Registry's `safe_broadcast` calls to confirm exact event format.
- **Validation time:** 10 minutes.

### Risk 2: `Cortex.Agent.Registry` name collision between local and external agents

- **Risk:** A local Agent.Server could theoretically register with the same key as an ExternalAgent, causing a startup failure.
- **Impact:** ExternalAgent fails to start with `{:error, {:already_registered, _}}`.
- **Mitigation:** Local Agent.Server uses UUIDs as Registry keys. ExternalAgent uses string names (e.g., "backend-worker"). These namespaces are disjoint by convention. If collision is a concern, prefix ExternalAgent keys with `"external:"`. For MVP, rely on the natural namespace separation.
- **Validation time:** 5 minutes (check Agent.Server init to confirm UUID keys).

### Risk 3: GenServer.call timeout races with Provider.External timeout

- **Risk:** If GenServer.call timeout fires before Provider.External's receive timeout, the caller gets a `** (exit) exited in: GenServer.call` crash instead of a clean `{:error, :timeout}`.
- **Impact:** Caller crashes instead of receiving an error tuple.
- **Mitigation:** Set GenServer.call timeout to `provider_timeout + 5_000ms`. Provider.External's internal receive timeout always fires first, returning `{:error, :timeout}` cleanly. The +5s buffer accounts for scheduling jitter.
- **Validation time:** 5 minutes (unit test with short timeout).

### Risk 4: PendingTasks or PubSub not started in test environment

- **Risk:** Tests fail because `Cortex.PubSub` or `PendingTasks` aren't started in the test setup.
- **Impact:** Test failures that aren't bugs in ExternalAgent.
- **Mitigation:** Test setup explicitly starts required processes: `start_supervised!(PendingTasks)`, `start_supervised!({Phoenix.PubSub, name: Cortex.PubSub})`, `start_supervised!(Gateway.Registry)`. Use test helpers to isolate process names.
- **Validation time:** 10 minutes.

---

## Recommended API Surface

### `Cortex.Agent.ExternalAgent` (GenServer)

| Function | Spec | Behavior |
|----------|------|----------|
| `start_link(opts)` | `(keyword()) :: GenServer.on_start()` | Confirm sidecar in Registry, subscribe to PubSub, store state |
| `run(server, prompt, opts)` | `(server, String.t(), keyword()) :: {:ok, TeamResult.t()} \| {:error, term()}` | Delegate to Provider.External, block until result |
| `get_state(server)` | `(server) :: {:ok, map()}` | Return name, agent_id, status, agent_info |
| `stop(server)` | `(server) :: :ok` | GenServer.stop with :normal |

### `Cortex.Agent.ExternalSupervisor` (DynamicSupervisor)

| Function | Spec | Behavior |
|----------|------|----------|
| `start_link(opts)` | `(keyword()) :: Supervisor.on_start()` | Start DynamicSupervisor |
| `start_agent(opts)` | `(keyword()) :: {:ok, pid()} \| {:error, term()}` | Start ExternalAgent child |
| `find_agent(name)` | `(String.t()) :: {:ok, pid()} \| :not_found` | Lookup running ExternalAgent by name via Agent.Registry |
| `stop_agent(name)` | `(String.t()) :: :ok \| {:error, :not_found}` | Terminate agent by name |
| `list_agents()` | `() :: [{String.t(), pid()}]` | All running external agents |

---

## Folder Structure

```
lib/cortex/agent/
  external_agent.ex         # ExternalAgent GenServer (NEW)
  external_supervisor.ex    # DynamicSupervisor for ExternalAgents (NEW)
  config.ex                 # existing -- Agent.Config (not modified)
  registry.ex               # existing -- Elixir Registry wrapper (not modified)
  server.ex                 # existing -- local Agent.Server (not modified)
  supervisor.ex             # existing -- local Agent.Supervisor (not modified)

test/cortex/agent/
  external_agent_test.exs       # ExternalAgent unit tests (NEW)
  external_supervisor_test.exs  # ExternalSupervisor unit tests (NEW)
```

**Ownership:**
- I own: `external_agent.ex`, `external_supervisor.ex`, and their tests.
- Executor Integration Engineer owns: wiring ExternalAgent into `executor.ex` and `application.ex`.

---

## Step-by-Step Task Plan

---

## Tighten the plan into 4-7 small tasks (STRICT)

### Task 1: ExternalAgent GenServer -- init + get_state

- **Outcome:** ExternalAgent GenServer starts, confirms sidecar in Gateway.Registry, subscribes to PubSub, stores state. `get_state/1` returns agent info.
- **Files to create:**
  - `lib/cortex/agent/external_agent.ex` (GenServer with `start_link/1`, `init/1`, `get_state/1`, `stop/1`)
  - `test/cortex/agent/external_agent_test.exs` (init success, init failure, get_state tests)
- **Exact verification commands:**
  ```bash
  mix test test/cortex/agent/external_agent_test.exs
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `feat(agent): add ExternalAgent GenServer with init + get_state`

### Task 2: ExternalAgent GenServer -- run/3 delegation to Provider.External

- **Outcome:** `run/3` builds a Provider.External handle from state, delegates to `Provider.External.run/3`, returns the result. Rejects dispatch on unhealthy agents.
- **Files to modify:**
  - `lib/cortex/agent/external_agent.ex` (add `run/3` client function + `handle_call`)
  - `test/cortex/agent/external_agent_test.exs` (add run success, run unhealthy, run timeout tests)
- **Exact verification commands:**
  ```bash
  mix test test/cortex/agent/external_agent_test.exs
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `feat(agent): add ExternalAgent.run/3 with Provider.External delegation`

### Task 3: ExternalAgent GenServer -- PubSub event handling

- **Outcome:** ExternalAgent handles `:agent_unregistered`, `:agent_registered`, and `:agent_status_changed` PubSub events. Disconnect marks unhealthy; reconnect restores healthy with updated agent info.
- **Files to modify:**
  - `lib/cortex/agent/external_agent.ex` (add `handle_info` clauses for PubSub events)
  - `test/cortex/agent/external_agent_test.exs` (add PubSub event tests: disconnect, reconnect, non-matching events ignored)
- **Exact verification commands:**
  ```bash
  mix test test/cortex/agent/external_agent_test.exs
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `feat(agent): add PubSub health monitoring to ExternalAgent`

### Task 4: ExternalSupervisor DynamicSupervisor

- **Outcome:** DynamicSupervisor that manages ExternalAgent children with `start_agent/1`, `stop_agent/1`, `list_agents/0`.
- **Files to create:**
  - `lib/cortex/agent/external_supervisor.ex`
  - `test/cortex/agent/external_supervisor_test.exs`
- **Exact verification commands:**
  ```bash
  mix test test/cortex/agent/external_supervisor_test.exs
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `feat(agent): add ExternalSupervisor DynamicSupervisor`

### Task 5: Docs, specs, credo, full test suite

- **Outcome:** All `@moduledoc`, `@doc`, `@spec` annotations complete. Credo passes strict. Format check passes. All existing tests still pass.
- **Files to modify:**
  - `lib/cortex/agent/external_agent.ex` (finalize docs)
  - `lib/cortex/agent/external_supervisor.ex` (finalize docs)
- **Exact verification commands:**
  ```bash
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix credo --strict
  mix test
  ```
- **Suggested commit message:** `docs(agent): finalize ExternalAgent + ExternalSupervisor docs and specs`

---

## CLAUDE.md contributions (do NOT write the file; propose content)

### From ExternalAgent Engineer

**Coding style rules:**
- ExternalAgent follows the same patterns as Agent.Server: one GenServer per agent, registered in `Cortex.Agent.Registry`, supervised by a DynamicSupervisor with `:temporary` restart.
- PubSub subscriptions happen in `init/1`. Always handle unmatched PubSub events with a catch-all `handle_info`.
- Provider.External handles are built fresh per `run/3` call -- never cache them across calls.

**Dev commands:**
```bash
mix test test/cortex/agent/external_agent_test.exs      # ExternalAgent unit tests
mix test test/cortex/agent/external_supervisor_test.exs  # ExternalSupervisor tests
```

**Before you commit checklist:**
1. `mix format`
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix test` (all pass, including existing tests)
5. No `IO.inspect` or `dbg()` left in code

**Guardrails:**
- ExternalAgent does NOT deploy or manage sidecar processes -- it assumes the sidecar is already registered in Gateway.Registry. Sidecar deployment is Phase 4 (SpawnBackend).
- ExternalAgent does NOT modify Gateway.Registry, Provider.External, or the executor -- those are separate scopes.
- GenServer.call timeout must always exceed Provider.External's internal timeout to prevent GenServer exit crashes.

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture Explanation
- ExternalAgent is the Elixir-side counterpart to a sidecar-connected agent. One GenServer per external agent.
- On init, it confirms the sidecar is registered in Gateway.Registry by name, caches the RegisteredAgent struct, and subscribes to Cortex.Events PubSub.
- `run/3` delegates to Provider.External (start/run/stop lifecycle) using a handle built from cached state. The caller blocks until the sidecar returns a TaskResult.
- PubSub events drive health state: `:agent_unregistered` -> unhealthy, `:agent_registered` (matching name) -> re-acquire and restore healthy.

### Key Engineering Decisions + Tradeoffs
- GenServer.call for `run/3` (synchronous) matches Provider.CLI's contract. One task at a time per agent.
- PubSub for health monitoring (not direct Process.monitor) avoids duplicating Gateway.Registry's monitor logic.
- Provider.External handle built fresh per call to avoid stale state after reconnect.
- Shared `Cortex.Agent.Registry` for process lookup (UUID vs name namespace separation by convention).

### Limits of MVP + Next Steps
- Single task at a time per ExternalAgent (no concurrent dispatch).
- Does not deploy sidecar (Phase 4 SpawnBackend will handle that).
- No capability-based routing -- ExternalAgent targets a specific sidecar by name.
- No persistence -- purely in-memory state, lost on restart.

### How to Run Locally + How to Validate
1. Start a Go sidecar connected to the Gateway (see `sidecar/README.md`)
2. Start Cortex: `mix phx.server`
3. The Executor Integration Engineer's code will automatically create ExternalAgents for `provider: external` teams
4. Validate: `mix test test/cortex/agent/external_agent_test.exs test/cortex/agent/external_supervisor_test.exs`

---

## READY FOR APPROVAL
