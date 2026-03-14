# Scaffold Lead — OTP Foundation Plan

---

## You are in PLAN MODE.

### Project
I want to build **Cortex**, a multi-agent orchestration system on Elixir/OTP.

**Goal:** build the **OTP foundation layer** in which we establish the Mix project, application supervision tree, agent registry, dynamic supervisor, event system, and all project boilerplate so that every other teammate (Agent Core, LLM Client, Tool Runtime) has a running application to plug into.

### Role + Scope
- **Role:** Scaffold Lead
- **Scope:** Mix project setup, `Cortex.Application` supervision tree, `Cortex.Agent.Supervisor` (DynamicSupervisor), `Cortex.Agent.Registry` (Registry wrapper), `Cortex.Events` (PubSub helper), config files, test helper, formatter, gitignore, and the top-level `Cortex` convenience module. I do NOT own Agent GenServer internals, LLM client, tool runtime, or any business logic.
- **File you will write:** `/docs/01-otp-foundation/plans/scaffold.md`
- **No-touch zones:** Do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** `mix compile` succeeds on a fresh clone with all dependencies resolved.
- **FR2:** `Cortex.Application` starts a supervision tree with five children: Phoenix.PubSub, Registry, DynamicSupervisor, Task.Supervisor, Tool.Registry.
- **FR3:** `Cortex.Agent.Supervisor.start_agent/1` starts a child process under the DynamicSupervisor; `stop_agent/1` terminates it; `list_agents/0` enumerates running children.
- **FR4:** `Cortex.Agent.Registry.lookup/1` returns `{:ok, pid}` or `:not_found`; `all/0` returns all registered `{id, pid}` pairs.
- **FR5:** `Cortex.Events.broadcast/2` publishes to PubSub on `"cortex:events"` topic; `subscribe/0` subscribes the calling process.
- **FR6:** `Cortex` top-level module exposes `start_agent/1`, `stop_agent/1`, `list_agents/0` delegating to the subsystems.
- **Tests required:** Unit tests for Registry, Events, Supervisor (start/stop/list), and Application boot. All async where possible.
- **Metrics required:** N/A for this phase — telemetry/Prometheus comes in Phase 10 (SRE).

## Non-Functional Requirements
- **Language/runtime:** Elixir ~> 1.17, OTP 27+
- **Local dev:** `mix deps.get && mix compile && mix test` — no Docker, no external services
- **Observability:** N/A this phase (Phase 10)
- **Safety:** Supervision tree must restart crashed children. DynamicSupervisor uses `:one_for_one` strategy. Registry and PubSub are fault-isolated from agent processes.
- **Test support:** `mix.exs` must set `elixirc_paths` to `["lib", "test/support"]` for `:test` env so test tool modules compile.
- **Documentation:** `@moduledoc` and `@doc` on every public module/function; typespecs on all public functions.
- **Performance:** N/A this phase (Phase 9)

---

## Assumptions / System Model
- **Deployment environment:** Local dev machine; no Docker, no clustering for Phase 1.
- **Failure modes:** A crashing agent GenServer is restarted by DynamicSupervisor (configurable restart strategy — default `:temporary` so failures don't cascade during orchestration). Registry auto-deregisters dead processes. PubSub is fire-and-forget (no delivery guarantees).
- **Delivery guarantees:** PubSub is best-effort broadcast. No persistence of events in Phase 1.
- **Multi-tenancy:** None. Single-node, single-user.

---

## Data Model (as relevant to this role)

### Event struct (used by `Cortex.Events`)
```
%{
  type: atom(),        # e.g. :agent_started, :agent_stopped, :agent_updated,
                       #      :run_started, :run_completed, :tier_started,
                       #      :tier_completed, :team_started, :team_completed
  payload: map(),      # arbitrary data relevant to the event
  timestamp: DateTime  # UTC timestamp of when the event was emitted
}
```

No persistence. Events are ephemeral PubSub messages for Phase 1.

### Registry entries
- Key: `agent_id` (string, UUID)
- Value: `pid` (the GenServer process)
- Stored in Elixir's built-in `Registry` — no custom storage.

### Validation rules
- Event `type` must be one of the defined atoms (enforced by typespec, not runtime validation in Phase 1).
- `agent_id` must be a non-empty binary string.

### Versioning strategy
- N/A for Phase 1. No config versioning needed yet.

### Persistence
- None. Everything is in-memory. Persistence comes in Phase 5 (LiveView Dashboard / Ecto).

---

## APIs (as relevant to this role)

### `Cortex` (top-level convenience)
| Function | Spec | Behavior |
|----------|------|----------|
| `start_agent(config)` | `@spec start_agent(map()) :: {:ok, pid()} \| {:error, term()}` | Delegates to `Cortex.Agent.Supervisor.start_agent/1` |
| `stop_agent(id)` | `@spec stop_agent(String.t()) :: :ok \| {:error, :not_found}` | Delegates to `Cortex.Agent.Supervisor.stop_agent/1` |
| `list_agents()` | `@spec list_agents() :: [{String.t(), pid()}]` | Delegates to `Cortex.Agent.Registry.all/0` |

### `Cortex.Agent.Supervisor`
| Function | Spec | Behavior |
|----------|------|----------|
| `start_agent(config)` | `@spec start_agent(map()) :: {:ok, pid()} \| {:error, term()}` | `DynamicSupervisor.start_child/2` with `Cortex.Agent.Server` child spec |
| `stop_agent(id)` | `@spec stop_agent(String.t()) :: :ok \| {:error, :not_found}` | Looks up pid via Registry, then `DynamicSupervisor.terminate_child/2` |
| `list_agents()` | `@spec list_agents() :: [{String.t(), pid()}]` | Delegates to `Cortex.Agent.Registry.all/0` |

### `Cortex.Agent.Registry`
| Function | Spec | Behavior |
|----------|------|----------|
| `lookup(agent_id)` | `@spec lookup(String.t()) :: {:ok, pid()} \| :not_found` | `Registry.lookup/2` on `Cortex.Agent.Registry` |
| `all()` | `@spec all() :: [{String.t(), pid()}]` | `Registry.select/2` to list all entries |
| `via_tuple(agent_id)` | `@spec via_tuple(String.t()) :: {:via, Registry, {Cortex.Agent.Registry, String.t()}}` | Produces the `:via` tuple for GenServer naming |

### `Cortex.Events`
| Function | Spec | Behavior |
|----------|------|----------|
| `broadcast(type, payload)` | `@spec broadcast(atom(), map()) :: :ok \| {:error, term()}` | `Phoenix.PubSub.broadcast(Cortex.PubSub, "cortex:events", %{type: type, payload: payload, timestamp: DateTime.utc_now()})` |
| `subscribe()` | `@spec subscribe() :: :ok \| {:error, term()}` | `Phoenix.PubSub.subscribe(Cortex.PubSub, "cortex:events")` |

### Error semantics
- `start_agent/1` returns `{:error, reason}` if the child spec is invalid or the GenServer fails to start.
- `stop_agent/1` returns `{:error, :not_found}` if no process is registered for the given id.
- `broadcast/2` returns `{:error, term()}` if PubSub is down (unlikely under supervision).

---

## Architecture / Component Boundaries

### Supervision tree (my scope)
```
Cortex.Application (top-level Supervisor, :one_for_one)
├── {Phoenix.PubSub, name: Cortex.PubSub}
├── {Registry, keys: :unique, name: Cortex.Agent.Registry}
├── {DynamicSupervisor, name: Cortex.Agent.Supervisor, strategy: :one_for_one}
├── {Task.Supervisor, name: Cortex.Tool.Supervisor}
└── {Cortex.Tool.Registry, []}
```

### Component boundaries
- **Cortex.Application** — I own this. Defines the child list. Other teammates' modules appear as child specs but I only need their module name, not their internals.
- **Cortex.Agent.Supervisor** — I own this. Thin wrapper over DynamicSupervisor. Delegates to Agent.Server (owned by Agent Core Lead) for child specs.
- **Cortex.Agent.Registry** — I own this. Thin wrapper over Registry. Agent Core Lead's Server module calls `via_tuple/1` during `start_link`.
- **Cortex.Events** — I own this. Pure helper module around Phoenix.PubSub. No state of its own.
- **Cortex.Tool.Supervisor** — Tool Runtime Lead owns the executor. I start the Task.Supervisor they plug into.
- **Cortex.Tool.Registry** — Tool Runtime Lead owns the implementation. I start it as a child in the supervision tree.

### Concurrency model
- Application supervisor is static (one-for-one, starts once).
- DynamicSupervisor spawns agent GenServers on demand.
- Registry is lock-free (ETS-backed).
- PubSub is ETS-backed broadcast (Phoenix.PubSub.PG2 adapter, local).

### Config propagation
- Static config via `config/*.exs` files, read at compile time.
- Runtime config not needed for Phase 1.
- No polling, no watch endpoint.

### Backpressure
- N/A for scaffold. Backpressure is relevant for LLM rate limiting (LLM Client Lead) and tool execution (Tool Runtime Lead).

---

## Correctness Invariants
1. **Application boots cleanly** — `Application.start(:cortex, :permanent)` succeeds and all five children are alive (PubSub, Registry, DynamicSupervisor, Task.Supervisor, Tool.Registry).
2. **Registry reflects running agents** — After `start_agent`, `lookup` returns the pid. After the process dies, `lookup` returns `:not_found`.
3. **DynamicSupervisor tracks children** — `DynamicSupervisor.count_children(Cortex.Agent.Supervisor)` matches the number of started (and not stopped) agents.
4. **Events are received by subscribers** — A process that calls `subscribe()` receives messages broadcast via `broadcast/2`.
5. **Stopping a non-existent agent returns error** — `stop_agent("nonexistent")` returns `{:error, :not_found}`, never crashes.
6. **Child ordering is safe** — PubSub and Registry start before DynamicSupervisor, so agents can register and broadcast during init.

---

## Tests

### Unit tests
- **`test/cortex/agent/registry_test.exs`** — `via_tuple/1` produces correct tuple; `lookup/1` returns `:not_found` for unknown id; after starting a process with via_tuple, `lookup/1` returns `{:ok, pid}`; `all/0` returns correct list.
- **`test/cortex/agent/supervisor_test.exs`** — `start_agent/1` returns `{:ok, pid}`; started agent appears in `list_agents/0`; `stop_agent/1` removes it; `stop_agent/1` on unknown id returns error.
- **`test/cortex/events_test.exs`** — `subscribe/0` + `broadcast/2` delivers message to subscriber; message has correct shape (type, payload, timestamp); non-subscriber does not receive message.
- **`test/cortex_test.exs`** — `Cortex.start_agent/1` / `stop_agent/1` / `list_agents/0` work end-to-end.

### Integration tests
- **`test/cortex/application_test.exs`** — Application starts successfully; all named processes are alive (Cortex.PubSub, Cortex.Agent.Registry, Cortex.Agent.Supervisor, Cortex.Tool.Supervisor).

### Property/fuzz tests
- N/A for scaffold. The Registry and PubSub are well-tested OTP/Phoenix primitives. Our wrappers are thin.

### Failure injection tests
- Deferred to Phase 2 (QE). The scaffold provides the structure; the QE phase will test crash recovery, supervisor restarts, and fault isolation.

### Commands
```bash
# Run all tests
mix test

# Run scaffold-specific tests
mix test test/cortex/agent/registry_test.exs
mix test test/cortex/agent/supervisor_test.exs
mix test test/cortex/events_test.exs
mix test test/cortex_test.exs
mix test test/cortex/application_test.exs

# Compile check
mix compile --warnings-as-errors
```

---

## Benchmarks + "Success"
N/A — Scaffold work is structural. There are no hot paths to benchmark. The supervision tree either starts or it doesn't. Performance benchmarks are Phase 9 scope.

**Success criteria for this role:** `mix deps.get && mix compile --warnings-as-errors && mix test` passes with zero failures, and `iex -S mix` drops into a running application with all five supervised processes alive.

---

## Engineering Decisions & Tradeoffs

### Decision 1: Use built-in `Registry` instead of a custom ETS-based or Agent-based registry
- **Alternatives considered:** (a) Roll our own ETS table for agent lookup; (b) Use an `Agent` process holding a map of id->pid.
- **Why:** `Registry` is purpose-built for this. It auto-cleans dead process entries via process monitoring, supports `:via` tuples for seamless GenServer naming, and is lock-free (partitioned ETS). Zero maintenance cost.
- **Tradeoff acknowledged:** We couple to Registry's API shape. If we ever need richer metadata per agent in the registry (e.g., role, status), we'd need a separate lookup or a custom layer on top. For Phase 1, the pid-only lookup is sufficient — agent state lives in the GenServer itself.

### Decision 2: `:temporary` restart strategy for agent children in DynamicSupervisor
- **Alternatives considered:** (a) `:permanent` — always restart; (b) `:transient` — restart only on abnormal exit.
- **Why:** Agents represent units of work with their own lifecycle. If an agent crashes during a DAG run, the orchestration layer (Phase 3) needs to decide whether to retry, skip, or fail the run. Automatic restarts would fight the orchestrator's decision-making. `:temporary` means "never restart" — the orchestrator handles recovery.
- **Tradeoff acknowledged:** A bug in agent init that kills the process won't auto-recover. Acceptable because: (a) the orchestrator will detect the failure via events, (b) the QE phase will validate init robustness, and (c) we can upgrade to `:transient` later if needed.

### Decision 3: Single PubSub topic (`"cortex:events"`) for all event types
- **Alternatives considered:** (a) Per-type topics (`"cortex:agent_started"`, `"cortex:run_completed"`, etc.); (b) Per-agent topics (`"cortex:agent:<id>"`).
- **Why:** Simplicity. A single topic with pattern matching on `%{type: type}` in `handle_info` is idiomatic Elixir and avoids topic management complexity. Most consumers (dashboard, orchestrator) want all events anyway.
- **Tradeoff acknowledged:** High event volume could cause unnecessary message delivery to subscribers that only care about a subset. For Phase 1 with a handful of agents, this is irrelevant. If it becomes a bottleneck, we can add topic-per-type as a layer on top without breaking the existing API.

### Decision 4: Application child ordering — PubSub and Registry before DynamicSupervisor
- **Alternatives considered:** No meaningful alternative — the dependency is structural.
- **Why:** Agent GenServers call `Registry` during `init` (via `via_tuple`) and broadcast to PubSub (`Events.broadcast(:agent_started, ...)`). If those aren't running yet, agent startup fails. OTP starts children in list order, so PubSub and Registry must appear first.
- **Tradeoff acknowledged:** This creates an implicit dependency between child ordering and agent init behavior. It's well-understood OTP practice, but a future refactor that changes init behavior could break if ordering isn't preserved. A comment in `application.ex` will document this.

---

## Risks & Mitigations

### Risk 1: Elixir/OTP version mismatch on dev machine
- **Risk:** `elixir ~> 1.17` requirement may not match installed version.
- **Impact:** `mix deps.get` or `mix compile` fails immediately.
- **Mitigation:** Verify with `elixir --version` before starting. Use `asdf` or `mise` for version management. Add `.tool-versions` file.
- **Validation time:** < 2 minutes.

### Risk 2: Circular dependency between Scaffold and Agent Core
- **Risk:** `Cortex.Agent.Supervisor.start_agent/1` needs to reference `Cortex.Agent.Server` for the child spec, but Agent Core Lead owns that module.
- **Impact:** Scaffold can't compile independently until Agent Core's module exists.
- **Mitigation:** Scaffold defines `start_agent/1` to accept a child spec or module+args tuple. Use a stub `Cortex.Agent.Server` in scaffold tests (a minimal GenServer that starts and registers). Agent Core Lead replaces the stub with the real implementation.
- **Validation time:** < 5 minutes.

### Risk 3: Phoenix.PubSub version compatibility with non-Phoenix project
- **Risk:** `phoenix_pubsub` is designed for Phoenix apps. Using it standalone might have unexpected behavior or missing dependencies.
- **Impact:** PubSub fails to start or broadcast.
- **Mitigation:** `phoenix_pubsub` 2.x is explicitly designed to work standalone (no Phoenix dependency). Validate with a minimal `Phoenix.PubSub.broadcast/3` call in a test.
- **Validation time:** < 3 minutes.

### Risk 4: Tool.Registry must exist before Application boots
- **Risk:** `Cortex.Tool.Registry` is listed as a child but owned by Tool Runtime Lead. If the module doesn't exist, Application won't start.
- **Impact:** `mix test` fails because Application can't boot.
- **Mitigation:** Scaffold creates the Tool.Registry module (Agent-based, with start_link/1) or Tool Runtime Lead delivers it first. Coordinate build order: Tool.Registry is built in Task 1 of Tool Runtime Lead's plan.
- **Validation time:** < 5 minutes.

---

## Recommended API Surface

(See the APIs section above for full specs.)

Summary of public functions:
1. `Cortex.start_agent/1` — start a supervised agent
2. `Cortex.stop_agent/1` — stop an agent by id
3. `Cortex.list_agents/0` — list all running agents
4. `Cortex.Agent.Supervisor.start_agent/1` — DynamicSupervisor child start
5. `Cortex.Agent.Supervisor.stop_agent/1` — DynamicSupervisor child terminate
6. `Cortex.Agent.Supervisor.list_agents/0` — enumerate children
7. `Cortex.Agent.Registry.lookup/1` — find agent pid by id
8. `Cortex.Agent.Registry.all/0` — list all registered agents
9. `Cortex.Agent.Registry.via_tuple/1` — produce `:via` naming tuple
10. `Cortex.Events.broadcast/2` — publish event to PubSub
11. `Cortex.Events.subscribe/0` — subscribe to event stream

---

## Folder Structure

```
cortex/
├── .formatter.exs
├── .gitignore
├── mix.exs
├── config/
│   ├── config.exs
│   ├── dev.exs
│   └── test.exs
├── lib/
│   ├── cortex.ex                          # Top-level convenience module
│   └── cortex/
│       ├── application.ex                 # OTP Application — supervision tree
│       ├── events.ex                      # PubSub helper module
│       └── agent/
│           ├── supervisor.ex              # DynamicSupervisor wrapper
│           └── registry.ex                # Registry wrapper
├── test/
│   ├── test_helper.exs
│   ├── cortex_test.exs                    # Top-level integration
│   └── cortex/
│       ├── application_test.exs           # Application boot test
│       ├── events_test.exs                # PubSub broadcast/subscribe
│       └── agent/
│           ├── supervisor_test.exs        # DynamicSupervisor start/stop/list
│           └── registry_test.exs          # Registry lookup/all/via_tuple
└── docs/
    └── 01-otp-foundation/
        └── plans/
            └── scaffold.md                # This file
```

**Ownership:**
- Everything above is Scaffold Lead scope.
- Agent Core Lead adds: `lib/cortex/agent/server.ex`, `lib/cortex/agent/config.ex`, `lib/cortex/agent/state.ex` + tests.
- LLM Client Lead adds: `lib/cortex/llm/` directory + tests.
- Tool Runtime Lead adds: `lib/cortex/tool/` directory + tests.

---

## Step-by-Step Task Plan (4-7 Small Commits)

### Task 1: Mix project + boilerplate files
- **Outcome:** A valid Mix project that compiles with all dependencies.
- **Files to create:**
  - `mix.exs` — app `:cortex`, elixir `~> 1.17`, deps: `phoenix_pubsub`, `uniq`, `yaml_elixir`, `jason`. `elixirc_paths` set to `["lib", "test/support"]` for test env.
  - `config/config.exs` — import env-specific config, logger format
  - `config/dev.exs` — logger debug level
  - `config/test.exs` — logger warning level
  - `.formatter.exs` — standard inputs + import_deps
  - `.gitignore` — `_build/`, `deps/`, `*.beam`, `.elixir_ls/`, etc.
  - `test/test_helper.exs` — `ExUnit.start()`
- **Verification:**
  ```bash
  cd cortex && mix deps.get && mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `feat(scaffold): init mix project with deps and config`

### Task 2: Application module + supervision tree
- **Outcome:** `Cortex.Application` starts all five supervised children. `iex -S mix` boots cleanly.
- **Files to create:**
  - `lib/cortex/application.ex` — `start/2` with children list (PubSub, Registry, DynamicSupervisor, Task.Supervisor, Tool.Registry)
- **Files to modify:**
  - `mix.exs` — add `mod: {Cortex.Application, []}` to `application/0`
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  # In iex:
  iex -S mix -e "IO.inspect(Process.whereis(Cortex.Agent.Supervisor)); IO.inspect(Process.whereis(Cortex.Tool.Supervisor))"
  ```
- **Suggested commit message:** `feat(scaffold): add Application supervision tree with all children`

### Task 3: Agent Registry wrapper
- **Outcome:** `Cortex.Agent.Registry` provides `via_tuple/1`, `lookup/1`, and `all/0` over the OTP Registry.
- **Files to create:**
  - `lib/cortex/agent/registry.ex`
  - `test/cortex/agent/registry_test.exs`
- **Verification:**
  ```bash
  mix test test/cortex/agent/registry_test.exs --trace
  ```
- **Suggested commit message:** `feat(scaffold): add Agent.Registry wrapper with lookup and enumeration`

### Task 4: Agent DynamicSupervisor wrapper
- **Outcome:** `Cortex.Agent.Supervisor` can start, stop, and list agent processes.
- **Files to create:**
  - `lib/cortex/agent/supervisor.ex`
  - `test/cortex/agent/supervisor_test.exs` (uses a stub GenServer for testing)
- **Verification:**
  ```bash
  mix test test/cortex/agent/supervisor_test.exs --trace
  ```
- **Suggested commit message:** `feat(scaffold): add Agent.Supervisor with start/stop/list`

### Task 5: Events module (PubSub helper)
- **Outcome:** `Cortex.Events.broadcast/2` and `subscribe/0` work correctly over Phoenix.PubSub.
- **Files to create:**
  - `lib/cortex/events.ex`
  - `test/cortex/events_test.exs`
- **Verification:**
  ```bash
  mix test test/cortex/events_test.exs --trace
  ```
- **Suggested commit message:** `feat(scaffold): add Events module for PubSub broadcast/subscribe`

### Task 6: Top-level Cortex module + full integration
- **Outcome:** `Cortex.start_agent/1`, `stop_agent/1`, `list_agents/0` delegate correctly. All tests pass.
- **Files to create:**
  - `lib/cortex.ex`
  - `test/cortex_test.exs`
  - `test/cortex/application_test.exs`
- **Verification:**
  ```bash
  mix test --trace
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `feat(scaffold): add top-level Cortex module and integration tests`

---

## CLAUDE.md Contributions (do NOT write the file; propose content)

### From Scaffold Lead

**Coding style rules:**
- Module naming: `Cortex.<Component>.<Module>` (e.g., `Cortex.Agent.Registry`)
- All public functions must have `@doc`, `@spec`, and `@moduledoc` on the module
- Pattern match in function heads; avoid `case` when match will do
- Use `defstruct` with `@enforce_keys` for data structures
- Pipelines over nested calls; keep pipe chains under 5 steps
- Alias modules at the top of the file, never inline

**Dev commands:**
```bash
mix deps.get          # Install dependencies
mix compile           # Compile (add --warnings-as-errors for CI)
mix test              # Run all tests
mix test --trace      # Run tests with verbose output
mix format            # Auto-format code
mix format --check-formatted  # CI format check
iex -S mix            # Interactive shell with app running
```

**Before you commit checklist:**
1. `mix format --check-formatted` passes
2. `mix compile --warnings-as-errors` passes (no warnings)
3. `mix test` passes with zero failures
4. All new public functions have `@doc` and `@spec`
5. No `IO.inspect` left in production code
6. No hardcoded API keys or secrets

**Guardrails:**
- Never start GenServers outside the supervision tree (use DynamicSupervisor)
- Never `Process.exit/2` an agent — use `Cortex.Agent.Supervisor.stop_agent/1`
- Never call `:erlang.halt/0` in application code
- The Application children list order matters — PubSub and Registry must start before DynamicSupervisor. Add a comment if you change it.

---

## EXPLAIN.md Contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture
- Cortex.Application starts a flat supervision tree with five children
- PubSub and Registry start first (dependencies for agent init)
- DynamicSupervisor spawns agent GenServers on demand
- Registry provides O(1) lookup by agent_id via ETS partitions
- Events module wraps PubSub for typed event broadcasting

### Key Engineering Decisions + Tradeoffs
- Built-in Registry over custom ETS — auto-cleanup, `:via` tuple support, zero maintenance; gives up rich metadata per entry
- `:temporary` restart for agents — orchestrator controls retry; gives up automatic recovery for simplicity
- Single PubSub topic for all events — simple pattern matching; gives up topic-level filtering

### Limits of MVP + Next Steps
- No persistence — events and agent state are in-memory only
- Stub RateLimiter — real implementation comes from LLM Client Lead
- No runtime config — all config is compile-time via `config/*.exs`
- No clustering / distribution — single BEAM node only
- Next: Agent Core Lead plugs in GenServer, LLM Client Lead replaces stub, Tool Runtime Lead adds execution

### How to Run Locally + How to Validate
- `mix deps.get && mix compile && mix test` — full validation
- `iex -S mix` — interactive shell, all processes running
- `Process.whereis(Cortex.Agent.Supervisor)` — verify supervisor is alive
- `Cortex.list_agents()` — should return `[]` on fresh start
- `Cortex.Events.subscribe()` then `Cortex.Events.broadcast(:test, %{msg: "hello"})` — verify PubSub

---

## READY FOR APPROVAL
