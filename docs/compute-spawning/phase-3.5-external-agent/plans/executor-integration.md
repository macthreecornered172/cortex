# Executor Integration Plan

## You are in PLAN MODE.

### Project
I want to do a **Phase 3.5 — ExternalAgent Integration**.

**Goal:** Wire the ExternalAgent GenServer into the executor flow so that `provider: external` in YAML config automatically routes through ExternalAgent, which manages the sidecar lifecycle via Provider.External internally.

### Role + Scope (fill in)
- **Role:** Executor Integration Engineer
- **Scope:** I own the executor-side wiring that detects `Provider.External` resolution and routes through ExternalAgent instead of the generic `start/run/stop` path. I also own adding `ExternalSupervisor` to the application supervision tree, and the executor-external test suite. I do NOT own ExternalAgent itself, Provider.External, PendingTasks, Gateway.Registry, or sidecar lifecycle — those are the ExternalAgent Engineer's scope.
- **File you will write:** `docs/compute-spawning/phase-3.5-external-agent/plans/executor-integration.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** When `ProviderResolver.resolve!/2` returns `Cortex.Provider.External`, the executor must start (or look up) an ExternalAgent GenServer for the team_name, then call `ExternalAgent.run/3` instead of the generic `provider_mod.start/run/stop` sequence.
- **FR2:** When `ProviderResolver.resolve!/2` returns any other provider (CLI, HTTP), the existing generic `start/run/stop` path must remain completely unchanged.
- **FR3:** `Cortex.Agent.ExternalSupervisor` must be present in the application supervision tree so that ExternalAgent GenServers can be dynamically started under it.
- **FR4:** After ExternalAgent.run returns, the executor must convert the result to the same `{team_name, :ok | {:error, _}, data}` outcome tuple format that the rest of `run_team/6` expects.
- **FR5:** If ExternalAgent startup fails (e.g., `:agent_not_found` because sidecar isn't registered), the executor must return a proper error outcome — not crash.
- **Tests required:** Unit tests for the executor external path and a regression test for the CLI path. Integration test with mock sidecar.
- **Metrics required:** N/A — ExternalAgent and Provider.External already emit telemetry events. The executor doesn't need additional metrics for this routing change.

## Non-Functional Requirements
- Language/runtime: Elixir 1.16+ / OTP 26+
- Local dev: `mix test` runs all tests; no Docker needed for the executor integration layer
- Observability: Existing telemetry events from Provider.External and ExternalAgent cover task dispatch and completion
- Safety: ExternalAgent startup failures and timeouts must produce clean error tuples, never crash the executor Task
- Documentation: CLAUDE.md contributions proposed below
- Performance: N/A — the routing logic adds one GenServer lookup/start, negligible overhead

---

## Assumptions / System Model
- **Deployment environment:** Local development (mix test). The executor runs in `Task.async` inside `execute_tier/8`, so ExternalAgent.run must be safe to call from a Task process.
- **Failure modes:**
  - Sidecar not registered in Gateway.Registry → ExternalAgent.start_link returns `{:stop, :agent_not_found}` → executor returns error outcome
  - ExternalAgent.run times out → returns `{:error, :timeout}` → executor returns error outcome
  - ExternalSupervisor not started → `DynamicSupervisor.start_child` returns `{:error, :noproc}` → executor returns error outcome
- **Delivery guarantees:** Same as existing executor — at-most-once per team per tier. Retries are the orchestration layer's concern, not the executor's.
- **Multi-tenancy:** None. Each run is independent.

---

## Data Model (as relevant to your role)
N/A — not in scope for this role. The executor does not introduce any new data entities. It uses the existing `Config`, `Team`, `TeamResult`, and `Workspace` structs unchanged.

---

## APIs (as relevant to your role)

### Modified Internal API: `run_team/6` (private in Executor)

The core change is in the private `run_team/6` function (lines 401–492 of `executor.ex`). The current path at lines 454–480:

```elixir
provider_mod = ProviderResolver.resolve!(team, config.defaults)
provider_config = %{command: command, cwd: workspace.path}

with {:ok, handle} <- provider_mod.start(provider_config) do
  try do
    provider_mod.run(handle, prompt, run_opts)
  after
    provider_mod.stop(handle)
  end
end
```

Becomes a two-branch dispatch:

```elixir
provider_mod = ProviderResolver.resolve!(team, config.defaults)

result =
  case provider_mod do
    Cortex.Provider.External ->
      run_via_external_agent(team_name, prompt, run_opts)

    _other ->
      # Existing generic path — unchanged
      provider_config = %{command: command, cwd: workspace.path}
      with {:ok, handle} <- provider_mod.start(provider_config) do
        try do
          provider_mod.run(handle, prompt, run_opts)
        after
          provider_mod.stop(handle)
        end
      end
  end
```

### New Private Function: `run_via_external_agent/3`

```elixir
defp run_via_external_agent(team_name, prompt, run_opts) do
  case ensure_external_agent(team_name) do
    {:ok, agent_pid} ->
      Cortex.Agent.ExternalAgent.run(agent_pid, prompt, run_opts)

    {:error, reason} ->
      {:error, reason}
  end
end
```

### New Private Function: `ensure_external_agent/1`

Looks up a running ExternalAgent by team_name, or starts one under ExternalSupervisor:

```elixir
defp ensure_external_agent(team_name) do
  case Cortex.Agent.ExternalSupervisor.find_agent(team_name) do
    {:ok, pid} ->
      {:ok, pid}

    :not_found ->
      Cortex.Agent.ExternalSupervisor.start_agent(name: team_name)
  end
end
```

### Consumed API: ExternalAgent (built by ExternalAgent Engineer)

The executor depends on these functions from ExternalAgent (teammate's scope):
- `ExternalAgent.run(server, prompt, opts)` — GenServer.call, returns `{:ok, TeamResult.t()} | {:error, term()}`
- `ExternalSupervisor.start_agent(opts)` — starts an ExternalAgent child, returns `{:ok, pid} | {:error, term()}`
- `ExternalSupervisor.find_agent(team_name)` — looks up a running ExternalAgent by name, returns `{:ok, pid} | :not_found`

### Supervision Tree Addition

In `lib/cortex/application.ex`, add `ExternalSupervisor` to the children list, after `Cortex.Gateway.Supervisor`:

```elixir
Cortex.Gateway.Supervisor,
{Cortex.Agent.ExternalSupervisor, name: Cortex.Agent.ExternalSupervisor},
```

Alternatively, this could live inside `Gateway.Supervisor` as a sibling of `PendingTasks`. The decision is: add it to `application.ex` directly for visibility and independent restart semantics — if ExternalSupervisor crashes, Gateway.Registry and PendingTasks are unaffected.

---

## Architecture / Component Boundaries (as relevant)

### Component: Executor (modified)
- **Responsibility:** Detects when Provider.External is resolved, routes through ExternalAgent instead of generic provider lifecycle.
- **Owns:** The `case provider_mod` dispatch branch in `run_team/6`, `run_via_external_agent/3`, `ensure_external_agent/1`.
- **Does NOT own:** ExternalAgent GenServer, ExternalSupervisor internals, Provider.External dispatch logic.

### Component: ExternalSupervisor (supervision tree entry)
- **Responsibility:** DynamicSupervisor that hosts ExternalAgent GenServers.
- **Added to:** `Cortex.Application` supervision tree.
- **Implementation:** Built by ExternalAgent Engineer; I only add the tree entry.

### Component: ExternalAgent (consumed, not owned)
- **Responsibility:** Owns the sidecar relationship, delegates to Provider.External internally.
- **Interface consumed by executor:** `run/3`, plus supervisor's `start_agent/1` and `find_agent/1`.

### How the flow works end-to-end

```
YAML: provider: external
  → ProviderResolver.resolve! → Cortex.Provider.External
  → Executor.run_team detects Provider.External
  → ensure_external_agent(team_name)
    → ExternalSupervisor.find_agent or start_agent
  → ExternalAgent.run(pid, prompt, opts)
    → [internally] Provider.External.start/run/stop
    → [internally] Gateway.Registry lookup, TaskPush, PendingTasks
  → {:ok, TeamResult} flows back to executor
  → executor converts to outcome tuple
```

### Concurrency model
- No change to concurrency model. Teams in each tier still run in parallel via `Task.async` + `Task.await_many`. Each Task process calls `run_team/6`, which now may route through ExternalAgent. ExternalAgent.run is a `GenServer.call` — it blocks the Task process until the result arrives, same as Provider.CLI blocks via port I/O.

### Backpressure
- No new backpressure needed. The existing `@default_task_timeout_ms` (60 min) applies to the Task.await_many call. ExternalAgent.run has its own internal timeout (default 30 min).

---

## Correctness Invariants (must be explicit)

1. **Provider.CLI path unchanged:** When `provider_mod` is not `Provider.External`, the executor follows the exact same `start/run/stop` code path as before. No regressions.
2. **ExternalAgent started once per team_name:** `ensure_external_agent/1` first checks for an existing agent via `find_agent/1` before starting a new one. Two concurrent calls for the same team_name in different tiers would reuse the same GenServer.
3. **Error propagation preserved:** `{:error, reason}` from `ExternalAgent.run/3` or from `ensure_external_agent/1` feeds into the existing `case result do` block at line 482, producing the correct `{team_name, {:error, reason}, data}` outcome tuple.
4. **Timeout semantics:** ExternalAgent.run has its own timeout (inherited from Provider.External config, default 30 min). The outer `Task.await_many(@default_task_timeout_ms)` at line 366 is 60 min. The inner timeout fires first, producing a clean `{:error, :timeout}`.
5. **Outcome tuple format:** The external path returns exactly the same tuple shape as the CLI path: `{team_name, :ok, %{type: :success, result: team_result}}` on success, `{team_name, {:error, reason}, %{type: :error, reason: reason}}` on failure.
6. **Supervisor presence:** ExternalSupervisor is in the app supervision tree. If it's not started (e.g., test env), `ensure_external_agent` returns `{:error, :noproc}`, which becomes a clean error outcome.

---

## Tests

### Unit Tests: `test/cortex/orchestration/runner/executor_external_test.exs`

- **Test 1: External provider routes through ExternalAgent** — Build a Config with `provider: :external`, mock ExternalSupervisor.find_agent to return a pid, mock ExternalAgent.run to return `{:ok, %TeamResult{}}`, call `run_team`, assert the outcome is `{team_name, :ok, %{type: :success, ...}}`.
- **Test 2: ExternalAgent start failure → error outcome** — Mock ExternalSupervisor.find_agent → `:not_found`, mock start_agent → `{:error, :agent_not_found}`, assert outcome is `{team_name, {:error, :agent_not_found}, ...}`.
- **Test 3: ExternalAgent.run timeout → error outcome** — Mock run → `{:error, :timeout}`, assert outcome is `{team_name, {:error, :timeout}, ...}`.
- **Test 4: CLI provider path unchanged (regression)** — Build a Config with `provider: :cli`, use the existing mock script pattern from `runner_test.exs`, assert the standard `start/run/stop` path works identically.
- **Test 5: ExternalAgent.run error status → failure outcome** — Mock run → `{:ok, %TeamResult{status: :error}}`, assert outcome is `{team_name, {:error, :error}, %{type: :failure, ...}}`.

### Integration Test (in same file, tagged `@tag :integration`)

- **Setup:** Start Gateway.Registry, PendingTasks, ExternalSupervisor, and a mock sidecar agent process (registers in Gateway.Registry with a fake stream pid).
- **Test: End-to-end DAG run with provider: external** —
  1. Build a single-team Config with `provider: :external`
  2. Register a mock agent in Gateway.Registry matching the team name
  3. Start a process that simulates the sidecar: when it receives a `TaskRequest`, it calls `Gateway.Registry.route_task_result/2` with a success `TaskResult`
  4. Call `Executor.execute/7`
  5. Assert the run completes with `{:ok, summary}` where summary shows the team completed
  6. Assert the mock sidecar received the expected prompt
- **Test: Cleanup on completion** — After the run completes, verify the ExternalAgent process is still alive (it persists for potential reuse, unlike the CLI start/stop pattern).

### Commands

```bash
mix test test/cortex/orchestration/runner/executor_external_test.exs
mix test test/cortex/orchestration/runner/executor_external_test.exs --trace
mix test  # full suite to verify no regressions
```

---

## Benchmarks + "Success"
N/A — The executor routing change adds one `case` branch and one GenServer lookup. This is not on the critical performance path. The actual work (Provider.External dispatch, sidecar communication) already has telemetry instrumentation. Benchmarking the routing overhead is not meaningful.

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### Decision 1: Pattern-match on `Provider.External` module in executor vs. adding a `mode/0` callback to the Provider behaviour

- **Decision:** Pattern-match directly on `Cortex.Provider.External` in the `case provider_mod` dispatch.
- **Alternatives considered:**
  1. Add a `@callback mode() :: :direct | :managed` to the Provider behaviour, where `:managed` means "route through a GenServer wrapper". Executor checks `provider_mod.mode()`.
  2. Wrap all providers in a GenServer (unify CLI and External under one lifecycle pattern).
- **Why:** Direct pattern match is the simplest possible change — one `case` clause, zero new abstractions. The Provider behaviour is already well-defined with `start/run/stop`. Adding a `mode/0` callback introduces a leaky abstraction: the behaviour shouldn't know how the executor invokes it. And wrapping CLI in a GenServer adds unnecessary overhead for the 95% case.
- **Tradeoff acknowledged:** If a third managed-lifecycle provider appears (unlikely in the near term), we'd add another clause to the case. At that point we'd refactor to a more general dispatch mechanism. For now, YAGNI.

### Decision 2: ExternalSupervisor in application.ex vs. inside Gateway.Supervisor

- **Decision:** Add `ExternalSupervisor` directly to `Cortex.Application` children, after `Gateway.Supervisor`.
- **Alternatives considered:**
  1. Add it as a child of `Gateway.Supervisor` alongside `PendingTasks` and `Gateway.Health`.
  2. Create a new `ExternalAgent.Supervisor` that wraps both ExternalSupervisor and any future ExternalAgent infrastructure.
- **Why:** ExternalSupervisor is conceptually a peer of Gateway.Supervisor, not a child. An ExternalAgent crash shouldn't take down Gateway.Registry or PendingTasks (which serve all external agents, not just the crashed one). Placing it at the application level gives it independent restart semantics.
- **Tradeoff acknowledged:** Application.ex gets one more child, slightly increasing its size. Gateway.Supervisor is already the natural home for "gateway adjacent" services. But fault isolation wins here — ExternalAgent lifecycle failures should be contained.

### Decision 3: `ensure_external_agent/1` lookup-or-start vs. always-start

- **Decision:** Look up an existing ExternalAgent first, start only if not found.
- **Alternatives considered:**
  1. Always start a fresh ExternalAgent for each `run_team` call, stop it after.
  2. Pre-start all ExternalAgents at the beginning of `execute/7` based on config analysis.
- **Why:** Lookup-or-start is the simplest approach that handles both single-run and multi-tier DAG scenarios. In a multi-tier DAG, if team "backend" appears in tier 0 and again in a continuation, the same ExternalAgent (and sidecar relationship) is reused. Always-start would lose the sidecar health monitoring state between calls. Pre-start would require config introspection and adds complexity for no clear benefit.
- **Tradeoff acknowledged:** There's a subtle race if two teams with the same name run concurrently (not possible in the current DAG model, but theoretically). `find_agent` + `start_agent` is not atomic. This is acceptable because the DAG guarantees each team name appears once per tier, and tiers run sequentially.

---

## Risks & Mitigations (REQUIRED)

### Risk 1: ExternalAgent API not finalized
- **Risk:** ExternalAgent Engineer's `run/3` or `ExternalSupervisor.find_agent/1` signatures may differ from what I assume.
- **Impact:** Compilation failure; executor can't call ExternalAgent.
- **Mitigation:** The kickoff.yaml specifies the API contract clearly. I'll code against the interface described there. The two plans should be reviewed together before either writes code. If signatures change, the executor adapter is a ~5 line fix.
- **Validation time:** < 5 minutes (read ExternalAgent plan, compare function signatures).

### Risk 2: GenServer.call timeout interaction with Task.await_many
- **Risk:** ExternalAgent.run uses GenServer.call with a timeout. If the call itself raises (`:timeout` exit), the Task process dies, and Task.await_many gets `{:exit, :timeout}` instead of a clean error tuple.
- **Impact:** Executor treats it as a crash rather than a timeout error. The tier fails with an exit rather than a clean `{:error, :timeout}`.
- **Mitigation:** ExternalAgent.run should use `GenServer.call(server, {:run, prompt, opts}, :infinity)` and handle timeout internally via `receive/after` (which Provider.External already does). Alternatively, the executor can wrap the call in a try/catch for `:exit` signals. I'll validate by checking ExternalAgent's implementation.
- **Validation time:** < 10 minutes (read ExternalAgent.run implementation, verify timeout handling).

### Risk 3: ExternalSupervisor not started in test environment
- **Risk:** Tests that don't explicitly start ExternalSupervisor will get `{:error, :noproc}` when `ensure_external_agent` tries to start a child.
- **Impact:** Tests fail or need boilerplate setup.
- **Mitigation:** Unit tests will mock `ExternalSupervisor.find_agent/1` and `start_agent/1` directly, avoiding the need for the actual supervisor. Integration tests will start the supervisor in setup. Document this in the test file.
- **Validation time:** < 5 minutes (run the test, check if supervisor is needed).

### Risk 4: Existing runner_test.exs tests break
- **Risk:** Modifying `run_team/6` could inadvertently affect tests that exercise the CLI path.
- **Impact:** CI failures on existing tests.
- **Mitigation:** The change is purely additive — a new `case` branch. The existing branch is the `_other ->` default clause, so no existing behavior changes. Run `mix test test/cortex/orchestration/runner_test.exs` before and after to confirm zero diff in test results.
- **Validation time:** < 2 minutes (run existing tests).

---

# Recommended API surface

## Functions/Endpoints

1. **`Executor.run_team/6` (modified private)** — Adds a `case provider_mod` dispatch that routes `Provider.External` through `run_via_external_agent/3`.

2. **`Executor.run_via_external_agent/3` (new private)** — Calls `ensure_external_agent/1` then `ExternalAgent.run/3`. Returns `{:ok, TeamResult.t()} | {:error, term()}`.

3. **`Executor.ensure_external_agent/1` (new private)** — Looks up or starts an ExternalAgent for the given team_name via ExternalSupervisor.

## Exact Behavior

- `run_via_external_agent(team_name, prompt, run_opts)`:
  - Calls `ensure_external_agent(team_name)`
  - On `{:ok, pid}` → calls `ExternalAgent.run(pid, prompt, run_opts)`
  - On `{:error, reason}` → returns `{:error, reason}`

- `ensure_external_agent(team_name)`:
  - Calls `ExternalSupervisor.find_agent(team_name)`
  - On `{:ok, pid}` → returns `{:ok, pid}`
  - On `:not_found` → calls `ExternalSupervisor.start_agent(name: team_name)`
  - Returns `{:ok, pid}` or `{:error, reason}`

---

# Folder structure

```
lib/cortex/
├── application.ex                          # MODIFY: add ExternalSupervisor child
├── orchestration/
│   └── runner/
│       └── executor.ex                     # MODIFY: add external agent dispatch
test/cortex/
└── orchestration/
    └── runner/
        └── executor_external_test.exs      # CREATE: new test file
```

No new packages or modules created by this role. ExternalAgent and ExternalSupervisor are created by the ExternalAgent Engineer.

---

# Step-by-step task plan in small commits

## Task 1: Add ExternalSupervisor to application supervision tree
- **Outcome:** ExternalSupervisor starts with the application and is available for dynamic child creation.
- **Files to create/modify:**
  - `lib/cortex/application.ex` — add `{Cortex.Agent.ExternalSupervisor, name: Cortex.Agent.ExternalSupervisor}` after `Cortex.Gateway.Supervisor`
- **Exact verification commands:**
  - `mix compile --warnings-as-errors`
  - `mix test test/cortex/orchestration/runner_test.exs` (no regressions)
- **Suggested commit message:** `feat(app): add ExternalSupervisor to application supervision tree`

## Task 2: Add external agent dispatch branch to executor
- **Outcome:** When ProviderResolver returns Provider.External, the executor routes through ExternalAgent.run instead of the generic start/run/stop path.
- **Files to create/modify:**
  - `lib/cortex/orchestration/runner/executor.ex` — add `run_via_external_agent/3`, `ensure_external_agent/1`, and the `case provider_mod` dispatch in `run_team/6`
- **Exact verification commands:**
  - `mix compile --warnings-as-errors`
  - `mix format --check-formatted`
  - `mix credo --strict`
- **Suggested commit message:** `feat(executor): route provider: external through ExternalAgent GenServer`

## Task 3: Write unit tests for executor external path
- **Outcome:** Unit tests verify: external provider routes through ExternalAgent, startup failure returns error outcome, timeout returns error outcome, CLI path is unchanged.
- **Files to create/modify:**
  - `test/cortex/orchestration/runner/executor_external_test.exs` — 5 unit tests
- **Exact verification commands:**
  - `mix test test/cortex/orchestration/runner/executor_external_test.exs --trace`
  - `mix test` (full suite, no regressions)
- **Suggested commit message:** `test(executor): add unit tests for ExternalAgent dispatch path`

## Task 4: Write integration test with mock sidecar
- **Outcome:** End-to-end integration test: Config with provider: external → executor starts ExternalAgent → dispatches to mock sidecar → receives result → run completes.
- **Files to create/modify:**
  - `test/cortex/orchestration/runner/executor_external_test.exs` — add integration test (tagged `@tag :integration`)
- **Exact verification commands:**
  - `mix test test/cortex/orchestration/runner/executor_external_test.exs --trace`
  - `mix test` (full suite)
- **Suggested commit message:** `test(executor): add integration test for external agent end-to-end flow`

## Task 5: Verify full CI suite and format/lint compliance
- **Outcome:** All tests pass, no warnings, no format issues, no credo violations.
- **Files to create/modify:** None (fix any issues found)
- **Exact verification commands:**
  - `mix format`
  - `mix compile --warnings-as-errors`
  - `mix credo --strict`
  - `mix test`
- **Suggested commit message:** `chore: fix lint/format issues from executor integration`

---

# CLAUDE.md contributions (do NOT write the file; propose content)

## From Executor Integration Engineer

### Coding Style
- When adding a new provider-specific dispatch path to the executor, use `case provider_mod` with explicit module matches — do not add callbacks to the Provider behaviour for executor-level routing concerns.
- Private helpers in executor.ex that handle a specific provider path should be named `run_via_<provider>/3` for consistency.

### Dev Commands
```bash
mix test test/cortex/orchestration/runner/executor_external_test.exs  # executor external tests
mix test test/cortex/orchestration/runner_test.exs                    # executor regression tests
```

### Before You Commit
- Run `mix test test/cortex/orchestration/runner_test.exs` to verify no regressions in the CLI path
- Verify that `mix compile --warnings-as-errors` passes — unused aliases from ExternalAgent imports are a common issue

### Guardrails
- Do not modify the generic `start/run/stop` path for non-External providers
- ExternalAgent.run must return the same `{:ok, TeamResult.t()} | {:error, term()}` shape as other providers — the executor's `case result do` block at the end of `run_team` must work identically for all providers

---

# EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

## Flow / Architecture Explanation
- The executor in `runner/executor.ex` is the point where provider-specific dispatch happens
- For `provider: external`, the executor bypasses the generic `start/run/stop` lifecycle and routes through `ExternalAgent.run/3`, which manages the sidecar relationship internally
- The `case provider_mod` dispatch at the top of `run_team/6` is the routing decision point
- `ensure_external_agent/1` implements lookup-or-start semantics: if an ExternalAgent for the team_name is already running (from a previous tier), it's reused

## Key Engineering Decisions + Tradeoffs
- Direct pattern match on `Provider.External` module rather than adding a `mode()` callback to Provider behaviour — simplicity over abstraction
- ExternalSupervisor placed in application.ex (not inside Gateway.Supervisor) for fault isolation
- Lookup-or-start semantics for ExternalAgent rather than always-start, to preserve sidecar health monitoring state across tiers

## Limits of MVP + Next Steps
- Only Provider.External gets special handling; future managed-lifecycle providers would need additional case clauses (refactor to dispatch table when > 2)
- ExternalAgent cleanup (stopping idle agents after a run completes) is not implemented — agents persist until the application stops
- No retry logic on ExternalAgent startup failure — the executor reports the error and the tier fails

## How to Run Locally + How to Validate
- `mix test test/cortex/orchestration/runner/executor_external_test.exs --trace` to see the external dispatch tests
- To test manually: create an orchestra.yaml with `provider: external`, start a Go sidecar, run `mix run -e "Cortex.Orchestration.Runner.execute_file(\"path/to/orchestra.yaml\")"` and observe the task dispatched to the sidecar

---

## READY FOR APPROVAL
