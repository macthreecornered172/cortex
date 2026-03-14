# Agent Core Lead Plan

## You are in PLAN MODE.

### Project
I want to build **Cortex**, a multi-agent orchestration system on Elixir/OTP.

**Goal:** build the **Agent GenServer core** in which we establish the fundamental unit of work -- an agent process with lifecycle management, configuration, state tracking, and event broadcasting -- that both DAG orchestration and gossip coordination modes depend on.

### Role + Scope
- **Role:** Agent Core Lead
- **Scope:** I own `Cortex.Agent.Server` (GenServer), `Cortex.Agent.Config` (configuration struct + validation), and `Cortex.Agent.State` (internal state struct). I do NOT own the supervision tree (`Cortex.Agent.Supervisor`, `Cortex.Agent.Registry`), the LLM client, the tool runtime, the event system implementation, config parsing (YAML), or the application module. I consume `Cortex.Events.PubSub` and `Cortex.Agent.Registry` as collaborator-provided dependencies.
- **File I will write:** `/docs/01-otp-foundation/plans/agent-core.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

- **FR1:** `Cortex.Agent.Config` validates agent configuration. `name` and `role` are required, non-empty strings. `model` defaults to `"sonnet"`. `max_turns` defaults to 200 (positive integer). `timeout_minutes` defaults to 30 (positive integer). `metadata` defaults to `%{}` (map).
- **FR2:** `Cortex.Agent.State` holds the runtime state of a single agent process. Fields: `id` (UUID, generated at init), `config` (Config struct), `status` (`:idle | :running | :done | :failed`), `metadata` (map, default `%{}`), `started_at` (DateTime), `updated_at` (DateTime).
- **FR3:** `Cortex.Agent.Server` is a GenServer that:
  - Initializes from a Config struct, generates a UUID, registers via Registry, broadcasts `:agent_started`.
  - Returns current state via `handle_call(:get_state, ...)`.
  - Updates status via `handle_call({:update_status, status}, ...)` with timestamp update and event broadcast.
  - Updates metadata via `handle_call({:update_metadata, key, value}, ...)` with timestamp update.
  - Receives work assignments via `handle_cast({:assign_work, work}, ...)`, transitions to `:running`, stores work in metadata, broadcasts `:agent_work_assigned`.
  - Broadcasts `:agent_stopped` on `terminate/2`.
- **FR4:** All public functions on `Cortex.Agent.Server` have a client API (e.g., `get_state/1`, `update_status/2`) that wraps GenServer calls with the via-tuple lookup.
- **Tests required:** Unit tests for Config validation, State struct construction, Server lifecycle (start, state queries, status transitions, metadata updates, work assignment, terminate). Integration test with real Registry + PubSub.
- **Metrics required:** N/A for Phase 1 -- Telemetry integration comes in Phase 10 (SRE). Event broadcasts via PubSub serve as the observability hook for now.

## Non-Functional Requirements

- Language/runtime: Elixir/OTP
- Local dev: Mix project (`mix compile`, `mix test`)
- Observability: All state transitions broadcast events via `Phoenix.PubSub` on the `Cortex.Events.PubSub` topic
- Safety: Invalid configs rejected at `new/1` with `{:error, reason}`. Invalid status transitions rejected with `{:error, :invalid_status}`. GenServer crash triggers supervisor restart (not our responsibility, but we must not swallow errors).
- Documentation: `@moduledoc` and `@doc` on all public functions; `@spec` typespecs on all public functions.
- Performance: N/A for this role -- agent creation is not a hot path. Benchmarks deferred to Phase 9.

---

## Assumptions / System Model

- **Deployment environment:** Local Mix project; later OTP releases. Single BEAM node for Phase 1.
- **Failure modes:** Agent GenServer crash -> DynamicSupervisor restarts it (supervisor is a collaborator's responsibility; our `init/1` must be idempotent and safe to re-invoke). If PubSub or Registry are down, agent startup will fail -- this is acceptable because the Application supervisor starts them first.
- **Multi-tenancy:** None for MVP. All agents share a single Registry and PubSub.
- **Persistence:** None. State is entirely in-process memory. Persistence comes in Phase 5 (LiveView Dashboard).
- **Agent IDs:** UUIDs generated via `Uniq.UUID.uuid4()`. IDs are ephemeral -- they do not survive process restarts. A restarted agent gets a new ID (acceptable for Phase 1; stable identity is a Phase 3+ concern).

---

## Data Model

### `Cortex.Agent.Config`

```
%Cortex.Agent.Config{
  name:            String.t()          # required, non-empty
  role:            String.t()          # required, non-empty
  model:           String.t()          # default "sonnet"
  max_turns:       pos_integer()       # default 200
  timeout_minutes: pos_integer()       # default 30
  metadata:        map()               # default %{}
}
```

- **Validation rules:**
  - `name`: must be a binary, `String.trim/1` must be non-empty.
  - `role`: must be a binary, `String.trim/1` must be non-empty.
  - `model`: must be a binary if provided.
  - `max_turns`: must be a positive integer (> 0).
  - `timeout_minutes`: must be a positive integer (> 0).
  - `metadata`: must be a map.
- **Construction:** `Config.new/1` accepts a map or keyword list, returns `{:ok, config}` or `{:error, reasons}` (list of validation error strings).
- **Versioning:** Not needed for Phase 1. Config is immutable once the agent starts.

### `Cortex.Agent.State`

```
%Cortex.Agent.State{
  id:         String.t()                                    # UUID, generated at init
  config:     Cortex.Agent.Config.t()                       # immutable after init
  status:     :idle | :running | :done | :failed            # starts :idle
  metadata:   map()                                         # mutable, for coordination
  started_at: DateTime.t()                                  # set at init
  updated_at: DateTime.t()                                  # updated on every mutation
}
```

- **Validation:** `status` must be one of the four allowed atoms. `id` must be a non-empty string.
- **Persistence:** In-memory only (lives inside the GenServer process dictionary via `%State{}` in the GenServer state).

---

## APIs

### `Cortex.Agent.Config`

```elixir
@spec new(map() | keyword()) :: {:ok, t()} | {:error, [String.t()]}
# Validates and constructs a Config struct. Returns error tuple with list of
# validation failure messages if invalid.

@spec new!(map() | keyword()) :: t() | no_return()
# Bang variant. Raises ArgumentError on validation failure.
```

### `Cortex.Agent.State`

```elixir
@spec new(Config.t()) :: t()
# Creates a new State from a validated Config. Generates UUID, sets status to
# :idle, timestamps to DateTime.utc_now/0.

@spec update_status(t(), :idle | :running | :done | :failed) :: {:ok, t()} | {:error, :invalid_status}
# Returns updated state with new status and updated_at, or error if status
# atom is not in the allowed set.

@spec update_metadata(t(), term(), term()) :: t()
# Sets metadata[key] = value, updates updated_at.
```

### `Cortex.Agent.Server` (Client API)

```elixir
@spec start_link(Config.t()) :: GenServer.on_start()
# Starts a new agent GenServer. Config must already be validated.
# Registers via Registry with the generated UUID as the key.

@spec get_state(String.t()) :: {:ok, State.t()} | {:error, :not_found}
# Retrieves the current state of an agent by ID.
# Returns {:error, :not_found} if the process is not registered.

@spec update_status(String.t(), :idle | :running | :done | :failed) :: :ok | {:error, :invalid_status | :not_found}
# Updates the agent's status. Broadcasts {:agent_status_changed, id, old_status, new_status}.

@spec update_metadata(String.t(), term(), term()) :: :ok | {:error, :not_found}
# Updates a single key in the agent's metadata map.

@spec assign_work(String.t(), term()) :: :ok
# Async. Casts work to the agent. Agent transitions to :running,
# stores work under metadata[:work], broadcasts :agent_work_assigned.

@spec stop(String.t()) :: :ok
# Gracefully stops the agent process. Triggers terminate/2 callback.
```

**Error semantics:**
- `:not_found` -- returned when the via-tuple lookup fails (process not in Registry). Caught by wrapping `GenServer.call/2` in a try/catch for `:exit` signals, or by doing a Registry lookup first.
- `:invalid_status` -- returned when the status atom is not in the allowed set.
- All `call`-based functions have a default timeout of 5000ms (GenServer default). This is fine for Phase 1.

---

## Architecture / Component Boundaries

### Components I Own

1. **`Cortex.Agent.Config`** -- Pure data module. No processes. Responsible for validation and struct construction.
2. **`Cortex.Agent.State`** -- Pure data module. No processes. Holds agent runtime state, provides update functions.
3. **`Cortex.Agent.Server`** -- GenServer. The running agent process. Holds a `%State{}` as its GenServer state. Registers itself in Registry, broadcasts events via PubSub.

### Components I Depend On (owned by collaborators)

- **`Cortex.Agent.Registry`** -- Registry for agent lookup by ID. I register via `{:via, Registry, {Cortex.Agent.Registry, agent_id}}`. I expect the Scaffold Lead to start this in the Application supervisor.
- **`Cortex.Events`** -- Event helper module wrapping Phoenix.PubSub. I broadcast events via `Cortex.Events.broadcast/2` on topic `"cortex:events"`. I expect the Scaffold Lead to start PubSub in the Application supervisor.

### How Config Changes Propagate

Config is immutable after agent creation. If you need to change config, stop the agent and start a new one. This simplifies reasoning enormously and avoids mid-execution config drift.

### Concurrency Model

Each agent is an isolated GenServer process. State mutations are serialized through the GenServer mailbox. No shared mutable state. No locks. Multiple agents run concurrently with zero coordination at the OTP level -- coordination happens at higher layers (DAG engine, gossip protocol).

### Supervision Strategy

Not my responsibility (Scaffold Lead owns `Cortex.Agent.Supervisor`), but my `init/1` must be safe for supervisor restarts:
- `init/1` generates a fresh UUID (no leftover state from prior incarnation).
- `init/1` registers in Registry (if the old registration is still hanging, the new process will fail to register -- this is correct behavior; the supervisor should handle it).
- `terminate/2` broadcasts `:agent_stopped` for cleanup.

---

## Correctness Invariants

1. **Status is always one of four atoms.** `update_status/2` rejects any atom not in `[:idle, :running, :done, :failed]`. No invalid status can ever be set.
2. **Config is immutable after init.** There is no API to mutate config on a running agent. The `config` field in State is never changed after `State.new/1`.
3. **Every state mutation updates `updated_at`.** Callers can rely on `updated_at` to detect staleness.
4. **Agent ID is unique within a BEAM node.** Guaranteed by UUID generation + Registry uniqueness constraint. `start_link` will fail with `{:error, {:already_registered, pid}}` if a duplicate ID is attempted (astronomically unlikely with UUIDv4, but the invariant holds structurally).
5. **Events are broadcast for all lifecycle transitions.** `:agent_started` on init, `:agent_status_changed` on status update, `:agent_work_assigned` on work assignment, `:agent_stopped` on terminate. Observers can reconstruct the full agent lifecycle from events alone.
6. **`name` and `role` are always non-empty strings.** Enforced at Config construction time. No agent can exist without a name and role.

---

## Tests

### Unit Tests

**`test/cortex/agent/config_test.exs`**
- Valid config with all fields -> `{:ok, %Config{}}`
- Valid config with only required fields (defaults applied) -> `{:ok, %Config{}}`
- Missing name -> `{:error, ["name is required"]}`
- Missing role -> `{:error, ["role is required"]}`
- Empty string name -> `{:error, ["name cannot be empty"]}`
- Blank string (whitespace only) role -> `{:error, ["role cannot be empty"]}`
- Non-positive max_turns -> `{:error, ["max_turns must be a positive integer"]}`
- Non-positive timeout_minutes -> error
- Multiple validation failures at once -> error list has all failures
- `new!/1` raises on invalid input
- `new!/1` returns struct on valid input

**`test/cortex/agent/state_test.exs`**
- `new/1` creates state with generated UUID, `:idle` status, timestamps set
- `update_status/2` with valid status returns `{:ok, updated_state}` with new `updated_at`
- `update_status/2` with invalid atom returns `{:error, :invalid_status}`
- `update_metadata/3` sets key and updates `updated_at`
- ID is a valid UUID string
- Config in state matches the input config

**`test/cortex/agent/server_test.exs`**
- `start_link/1` starts process, agent is registered in Registry
- `get_state/1` returns current state with `:idle` status
- `update_status/2` changes status and broadcasts event
- `update_status/2` with invalid status returns error, state unchanged
- `update_metadata/3` updates metadata map
- `assign_work/2` transitions to `:running`, stores work in metadata
- `stop/1` triggers terminate, broadcasts `:agent_stopped`
- `get_state/1` with unknown ID returns `{:error, :not_found}`
- Multiple agents can coexist (start two, query both)

### Integration Tests

**`test/cortex/agent/integration_test.exs`**
- Start agent, subscribe to PubSub, update status, verify event received with correct payload
- Start agent, assign work, verify `:agent_work_assigned` event
- Start agent, stop it, verify `:agent_stopped` event
- Start two agents, update both, verify events are received for each independently

### Property/Fuzz Tests

- N/A for Phase 1. Config validation is well-bounded and covered by unit tests. Property testing is a good Phase 2 QE addition.

### Failure Injection Tests

- N/A for this role. The Scaffold Lead and QE phases handle supervisor restart behavior. My `terminate/2` broadcasts an event, which is tested in integration tests.

### Commands

```bash
mix test test/cortex/agent/config_test.exs
mix test test/cortex/agent/state_test.exs
mix test test/cortex/agent/server_test.exs
mix test test/cortex/agent/integration_test.exs
mix test test/cortex/agent/           # all agent tests
mix test                               # full suite
```

---

## Benchmarks + "Success"

N/A -- Agent creation and state queries are not hot paths. An agent is created once and runs for minutes to hours. Benchmarking GenServer call latency at this scale is meaningless noise. Phase 9 (Performance) will benchmark under load if needed.

**Success for this role** is defined as:
- All tests pass (`mix test test/cortex/agent/` -- 0 failures).
- `mix compile --warnings-as-errors` produces no warnings.
- An agent can be started, queried, updated, assigned work, and stopped -- with correct events broadcast at each step.

---

## Engineering Decisions & Tradeoffs

### Decision 1: Immutable Config After Init

- **Decision:** `Cortex.Agent.Config` is set at agent creation and never modified. No `update_config` API exists.
- **Alternatives considered:** Mutable config with `handle_call({:update_config, new_config}, ...)` allowing runtime changes (e.g., changing model mid-run, adjusting timeout).
- **Why:** Immutability eliminates an entire class of bugs -- mid-execution config drift, race conditions between config reads and writes, and the question of what to do with in-flight work when config changes. It simplifies testing and reasoning. If you need different config, start a new agent.
- **Tradeoff acknowledged:** If a later phase needs to hot-swap config (e.g., dynamic model selection), we'll need to add an API. This is a one-function addition and doesn't require rearchitecting.

### Decision 2: Fresh UUID on Every Start (No Stable Identity Across Restarts)

- **Decision:** `init/1` generates a new UUID every time. A supervisor-restarted agent gets a new ID.
- **Alternatives considered:** Accept an `:id` field in Config so the supervisor can restart with the same ID, preserving identity for observers and external references.
- **Why:** Stable identity across restarts requires careful handling of stale Registry entries, dangling PubSub subscriptions, and split-brain scenarios (old process still draining while new process starts). For Phase 1, fresh IDs are simpler and correct. The DAG engine (Phase 3) will track agents by its own mapping, not raw process IDs.
- **Tradeoff acknowledged:** External observers (like a future dashboard) cannot correlate a restarted agent with its predecessor. Phase 3+ can add stable identity by passing `:id` through Config if needed -- the struct already accepts arbitrary fields via the map constructor.

### Decision 3: PubSub Broadcasting Over Direct Process Notification

- **Decision:** All lifecycle events are broadcast via `Phoenix.PubSub.broadcast/3` on a shared topic (`"cortex:events"`), not sent directly to known subscribers.
- **Alternatives considered:** Maintain a subscriber list in agent state and send messages directly via `send/2`. Lower overhead, no PubSub dependency.
- **Why:** PubSub decouples the agent from its observers completely. The agent doesn't know or care who's listening. New observers (dashboard, logger, metrics, DAG engine) can subscribe without modifying agent code. This is the standard OTP pattern for event-driven systems.
- **Tradeoff acknowledged:** PubSub adds a process hop and slight latency (~microseconds). Irrelevant at our scale. Also introduces a dependency on `Phoenix.PubSub` being started first -- handled by Application boot order.

### Decision 4: Separate Config and State Modules

- **Decision:** Config (input validation) and State (runtime data) are separate modules with separate structs.
- **Alternatives considered:** Single `Agent` struct that serves as both config and state, with status/timestamps added at runtime.
- **Why:** Separation of concerns. Config is validated at creation, immutable, and user-facing. State is internal to the GenServer, mutable, and system-facing. Conflating them makes it unclear which fields are user-settable vs. system-managed. Separate modules also make testing cleaner -- Config tests don't need a running GenServer.
- **Tradeoff acknowledged:** Two modules instead of one. Slightly more files. Worth it for clarity.

---

## Risks & Mitigations

### Risk 1: Registry/PubSub Not Started Before Agent

- **Risk:** If `Cortex.Agent.Server.start_link/1` is called before the Registry or PubSub are started by the Application supervisor, `init/1` will crash on registration or broadcast.
- **Impact:** Agent processes fail to start. Supervisor enters restart loop.
- **Mitigation:** Document the dependency clearly. In tests, use a setup block that starts Registry and PubSub. Coordinate with Scaffold Lead to ensure Application boot order is correct. Add a guard in `init/1` that returns `{:stop, :pubsub_not_started}` with a clear error if PubSub is unreachable (fail fast with useful message rather than cryptic crash).
- **Validation time:** 5 minutes -- write a test that starts an agent without PubSub and verify the error.

### Risk 2: Via-Tuple Lookup Failures Cause Unhandled Exits

- **Risk:** Calling `GenServer.call({:via, Registry, {Cortex.Agent.Registry, id}}, ...)` with an unknown ID causes an exit signal, not a clean error return.
- **Impact:** Callers crash if they don't handle the exit. This propagates up and could crash coordination processes.
- **Mitigation:** All client API functions (`get_state/1`, `update_status/2`, etc.) wrap the GenServer call in a `try/catch` or use `Registry.lookup/2` first. Return `{:error, :not_found}` cleanly. Test this explicitly.
- **Validation time:** 5 minutes -- write a test calling `get_state("nonexistent-id")` and verify `{:error, :not_found}`.

### Risk 3: PubSub Event Contract Drift

- **Risk:** Consumers of agent events (dashboard, DAG engine, logger) assume a specific event payload shape. If I change the broadcast format, downstream breaks silently.
- **Impact:** Integration failures in later phases that are hard to debug.
- **Mitigation:** Define event structs or at minimum document the exact payload shape in `@moduledoc`. Use a consistent format: `{event_type, %{agent_id: id, ...details}}`. Add a dedicated section in CLAUDE.md listing all event types and their payloads.
- **Validation time:** 10 minutes -- review all broadcast calls, document each, add a test that pattern-matches the exact payload shape.

### Risk 4: Namespace Collision With Future Modules

- **Risk:** Naming `Cortex.Agent.Server` could collide with or confuse against a future `Cortex.Agent` context module that provides the public API facade.
- **Impact:** Awkward renames or confusing import paths later.
- **Mitigation:** This is the standard Elixir convention (`MyApp.Thing.Server` for the GenServer, `MyApp.Thing` for the context). If a facade is added later, it will live at `Cortex.Agent` and delegate to `Cortex.Agent.Server`. No collision -- this is the expected layering.
- **Validation time:** 2 minutes -- confirm no other module is planned for `Cortex.Agent` in Phase 1.

---

## Recommended API Surface

### `Cortex.Agent.Config`

| Function | Spec | Behavior |
|----------|------|----------|
| `new/1` | `(map() \| keyword()) :: {:ok, t()} \| {:error, [String.t()]}` | Validate + construct |
| `new!/1` | `(map() \| keyword()) :: t() \| no_return()` | Bang variant, raises on failure |

### `Cortex.Agent.State`

| Function | Spec | Behavior |
|----------|------|----------|
| `new/1` | `(Config.t()) :: t()` | Construct from validated Config |
| `update_status/2` | `(t(), atom()) :: {:ok, t()} \| {:error, :invalid_status}` | Transition status |
| `update_metadata/3` | `(t(), term(), term()) :: t()` | Set metadata key |

### `Cortex.Agent.Server`

| Function | Spec | Behavior |
|----------|------|----------|
| `start_link/1` | `(Config.t()) :: GenServer.on_start()` | Start + register agent |
| `get_state/1` | `(String.t()) :: {:ok, State.t()} \| {:error, :not_found}` | Query state |
| `update_status/2` | `(String.t(), atom()) :: :ok \| {:error, term()}` | Change status + broadcast |
| `update_metadata/3` | `(String.t(), term(), term()) :: :ok \| {:error, :not_found}` | Update metadata |
| `assign_work/2` | `(String.t(), term()) :: :ok` | Async work assignment |
| `stop/1` | `(String.t()) :: :ok` | Graceful shutdown |

---

## Folder Structure

```
lib/
  cortex/
    agent/
      config.ex          # Config struct + validation       (I own)
      state.ex           # State struct + update functions   (I own)
      server.ex          # GenServer implementation          (I own)
      supervisor.ex      # DynamicSupervisor                 (Scaffold Lead)
      registry.ex        # Registry wrapper (if needed)      (Scaffold Lead)

test/
  cortex/
    agent/
      config_test.exs    # Config unit tests                 (I own)
      state_test.exs     # State unit tests                  (I own)
      server_test.exs    # Server unit tests                 (I own)
      integration_test.exs  # PubSub integration tests       (I own)
```

---

## Step-by-Step Task Plan (Small Commits)

### Task 1: Config Struct + Validation

**Outcome:** `Cortex.Agent.Config` module with `new/1`, `new!/1`, struct definition, validation logic, typespecs, and docs.

**Files to create:**
- `lib/cortex/agent/config.ex`
- `test/cortex/agent/config_test.exs`

**Verification:**
```bash
mix compile --warnings-as-errors
mix test test/cortex/agent/config_test.exs
```

**Suggested commit message:** `feat(agent): add Config struct with validation`

---

### Task 2: State Struct + Update Functions

**Outcome:** `Cortex.Agent.State` module with `new/1`, `update_status/2`, `update_metadata/3`, struct definition, typespecs, and docs. Depends on Config.

**Files to create:**
- `lib/cortex/agent/state.ex`
- `test/cortex/agent/state_test.exs`

**Verification:**
```bash
mix compile --warnings-as-errors
mix test test/cortex/agent/state_test.exs
```

**Suggested commit message:** `feat(agent): add State struct with status and metadata updates`

---

### Task 3: Server GenServer (Core Callbacks)

**Outcome:** `Cortex.Agent.Server` GenServer with `init/1`, `handle_call(:get_state)`, `handle_call({:update_status, ...})`, `handle_call({:update_metadata, ...})`, `handle_cast({:assign_work, ...})`, `terminate/2`. Client API functions wrapping each. Registry registration in `init/1`. PubSub broadcasts on lifecycle events.

**Files to create:**
- `lib/cortex/agent/server.ex`
- `test/cortex/agent/server_test.exs`

**Verification:**
```bash
mix compile --warnings-as-errors
mix test test/cortex/agent/server_test.exs
```

**Suggested commit message:** `feat(agent): add Server GenServer with lifecycle management`

---

### Task 4: Error Handling + Edge Cases

**Outcome:** Client API functions return `{:error, :not_found}` for unknown agent IDs. Invalid status transitions return `{:error, :invalid_status}`. `stop/1` handles already-stopped agents gracefully. Tests cover all error paths.

**Files to modify:**
- `lib/cortex/agent/server.ex` (add try/catch wrappers, stop/1)
- `test/cortex/agent/server_test.exs` (add error path tests)

**Verification:**
```bash
mix compile --warnings-as-errors
mix test test/cortex/agent/server_test.exs
```

**Suggested commit message:** `feat(agent): add error handling for not-found and invalid transitions`

---

### Task 5: Integration Tests (PubSub + Registry)

**Outcome:** Integration test that starts real Registry + PubSub, creates agents, subscribes to events, performs lifecycle operations, and verifies the correct events arrive with the correct payloads. Tests multi-agent coexistence.

**Files to create:**
- `test/cortex/agent/integration_test.exs`

**Verification:**
```bash
mix compile --warnings-as-errors
mix test test/cortex/agent/integration_test.exs
mix test test/cortex/agent/  # full agent test suite
```

**Suggested commit message:** `test(agent): add integration tests for PubSub event broadcasting`

---

## CLAUDE.md Contributions (do NOT write the file; propose content)

### From Agent Core Lead

**Coding Style:**
- Use `@enforce_keys` on all structs to catch missing required fields at compile time.
- Return `{:ok, value} | {:error, reason}` from all fallible public functions. Never raise in library code unless it's a `!` bang variant.
- Pattern match on function heads, not `case` inside function bodies. Example: `def handle_call(:get_state, _from, state)` not `def handle_call(msg, from, state) do case msg do ...`.
- All GenServer client API functions must handle the `:exit` case from `GenServer.call/2` for processes that are down.
- Events broadcast on PubSub use the format `{event_atom, %{agent_id: id, ...}}`. Current events: `:agent_started`, `:agent_status_changed`, `:agent_work_assigned`, `:agent_stopped`.

**Dev Commands:**
```bash
mix test test/cortex/agent/           # run all agent tests
mix test test/cortex/agent/config_test.exs   # config only
mix test test/cortex/agent/server_test.exs   # server only
mix compile --warnings-as-errors      # must pass before commit
```

**Before You Commit (Agent Core):**
1. `mix compile --warnings-as-errors` -- zero warnings.
2. `mix test test/cortex/agent/` -- all tests green.
3. Every public function has `@doc` and `@spec`.
4. No `IO.inspect` or `dbg()` left in code.
5. Event payloads match the documented format in `@moduledoc`.

**Guardrails:**
- Do NOT add `handle_info` catch-alls that swallow unknown messages. Let them crash -- the supervisor will restart.
- Do NOT store the agent PID in state. Use Registry lookups. PIDs change on restart.
- Do NOT add persistence, HTTP, or file I/O to agent modules. Those are separate concerns for later phases.

---

## EXPLAIN.md Contributions (do NOT write the file; propose outline bullets)

**Flow / Architecture:**
- Each agent is an independent GenServer process identified by a UUID.
- Agents register in a shared Registry at startup, enabling lookup by ID from anywhere in the BEAM.
- All lifecycle events (started, status changed, work assigned, stopped) are broadcast via PubSub, enabling decoupled observation.
- Config is validated once at construction and is immutable for the agent's lifetime.
- State mutations (status, metadata) are serialized through the GenServer mailbox -- no locks, no races.

**Key Engineering Decisions + Tradeoffs:**
- Immutable config: eliminates mid-run drift at the cost of requiring a new agent for config changes.
- Fresh UUID on restart: simpler than stable identity, but loses correlation across supervisor restarts.
- PubSub over direct messaging: decouples agents from observers, slight overhead that is irrelevant at our scale.
- Separate Config/State modules: more files, but clearer separation between user input and system state.

**Limits of MVP + Next Steps:**
- No stable agent identity across restarts (Phase 3+ concern for DAG engine).
- No state persistence -- agent state is lost on crash (Phase 5 adds SQLite persistence).
- No status transition validation (e.g., `:done` -> `:running` is allowed). Could add a state machine in Phase 2 QE if needed.
- No timeout enforcement -- `timeout_minutes` is stored but not acted upon (DAG engine in Phase 3 will enforce it).

**How to Run Locally + How to Validate:**
- `mix deps.get && mix compile --warnings-as-errors`
- `mix test test/cortex/agent/` -- all agent tests
- `iex -S mix` then `Cortex.Agent.Config.new!(%{name: "test", role: "worker"})` to interactively create a config
- Start an agent in iex: `{:ok, pid} = Cortex.Agent.Server.start_link(config)` then `Cortex.Agent.Server.get_state(agent_id)`

---

## READY FOR APPROVAL
