# Integration Engineer — Phase 1 Foundation Plan

## You are in PLAN MODE.

### Project
I want to do a **compute spawning abstraction layer** for Cortex.

**Goal:** build a **Provider + SpawnBackend abstraction** in which we **decouple the orchestration layer from the concrete `Spawner` module so that Cortex can dispatch work to any provider/backend combination without changing orchestration logic**.

### Role + Scope
- **Role:** Integration Engineer
- **Scope:** Wire the orchestration layer (`Runner.Executor`, `Runner`, `InternalAgent.Launcher`) to dispatch through the `Provider` behaviour instead of calling `Spawner` directly. Own the `Provider.Resolver` module. Do NOT own the Provider or SpawnBackend behaviour definitions, the CLI/Local implementations, or the config schema changes — those belong to the Behaviour Architect, CLI Refactor Engineer, and Config Engineer respectively.
- **File you will write:** `docs/compute-spawning/phase-1-foundation/plans/integration-engineer.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** `Runner.Executor.run_team/6` dispatches through `Provider.run/3` (or equivalent) instead of calling `Spawner.spawn/1` directly.
- **FR2:** `InternalAgent.Launcher.run/1` dispatches through `Provider.run/3` instead of calling `Spawner.spawn/1` directly, so mesh and gossip orchestrators also use the abstraction.
- **FR3:** `Provider.Resolver` resolves the correct Provider module given a Team struct (with optional `provider` field) and project Defaults (with optional `provider` field). Default resolution: no `provider` field → `Provider.CLI`.
- **FR4:** The `TeamResult` contract is preserved — all callers of Provider.run/3 receive `{:ok, TeamResult.t()} | {:error, term()}` exactly as today.
- **FR5:** All three orchestration modes (DAG, mesh, gossip) work through the new abstraction path.
- **Tests required:** unit tests for Provider.Resolver; integration tests verifying the full DAG execution flow still passes through the new dispatch path.
- **Metrics required:** N/A — no new Prometheus metrics; existing telemetry events remain unchanged.

## Non-Functional Requirements
- Language/runtime: Elixir 1.16+, Erlang/OTP 26+
- Local dev: `mix test` — no docker-compose needed
- Observability: Existing telemetry events (`Tel.emit_run_started`, `Tel.emit_tier_completed`, `Tel.emit_run_completed`) remain unchanged
- Safety: Backward-compatible — if no `provider` field is set in config, behaviour is identical to today. No new failure modes introduced.
- Documentation: `@moduledoc`, `@doc`, `@spec` on all public functions per project conventions
- Performance: No measurable overhead — resolver is a simple pattern match, called once per team spawn

---

## Assumptions / System Model
- Deployment environment: local (mix test); no external services required
- Failure modes: Provider module not found (invalid config value), Provider.run/3 returns error tuple — both propagate as `{:error, reason}` through existing error handling
- Delivery guarantees: N/A — synchronous call/response within the BEAM
- Multi-tenancy: None (MVP)
- **Key assumption:** The Behaviour Architect defines `Provider` with a `start/1` → `run/3` → `stop/1` lifecycle: `start(config)` returns a handle, `run(handle, prompt, run_opts)` executes the agent and returns `{:ok, TeamResult.t()} | {:error, term()}`, and `stop(handle)` cleans up. The Config Engineer will add `provider` and `backend` fields to `Defaults` and `Team` structs. I will consume both.

---

## Data Model

### Provider.Resolver
Not a data entity — a pure function module. Key type:

- **Input:** `Team.t()` (with optional `provider` field) + `Defaults.t()` (with optional `provider` field)
- **Output:** Provider module atom (e.g., `Cortex.Provider.CLI`)

### Resolution Rules
1. If `team.provider` is set → resolve that atom (e.g., `"cli"` → `Cortex.Provider.CLI`)
2. Else if `defaults.provider` is set → resolve that atom
3. Else → `Cortex.Provider.CLI` (the default)

### Validation
- The resolver checks that the resolved module exports the Provider behaviour callbacks
- Returns `{:ok, module}` or `{:error, {:unknown_provider, name}}`

---

## APIs

### Provider.Resolver

```elixir
@spec resolve(Team.t(), Defaults.t()) :: {:ok, module()} | {:error, term()}
def resolve(team, defaults)
```

Resolves the provider module for a given team and defaults. Used by `Executor.run_team/6` and `Launcher.run/1`.

```elixir
@spec resolve!(Team.t(), Defaults.t()) :: module()
def resolve!(team, defaults)
```

Bang variant — raises on unknown provider. Useful in contexts where the config has already been validated.

### Modified Executor.run_team/6 (internal, private)

Current signature is unchanged. Internally, instead of:
```elixir
Spawner.spawn(spawner_opts)
```
It becomes:
```elixir
provider_mod = Provider.Resolver.resolve!(team, config.defaults)
provider_config = build_provider_config(team, config.defaults, workspace, command)
{:ok, handle} = provider_mod.start(provider_config)

try do
  provider_mod.run(handle, prompt, run_opts)
after
  provider_mod.stop(handle)
end
```

Where:
- `provider_config` is a keyword list or map built from the team and defaults (e.g., `[command: command, cwd: workspace.path]`)
- `prompt` is the prompt string currently passed as `:prompt` in `spawner_opts` (already built by `Injection.build_prompt/4`)
- `run_opts` contains the remaining per-run options extracted from the current `spawner_opts`: `[team_name: ..., model: ..., max_turns: ..., permission_mode: ..., timeout_minutes: ..., log_path: ..., on_token_update: ..., on_activity: ..., on_port_opened: ...]`

The `try/after` block ensures `stop/1` is always called, even if `run/3` raises or returns an error.

### Modified InternalAgent.Launcher.run/1

Current signature is unchanged. Internally, instead of:
```elixir
config |> SpawnConfig.to_spawner_opts() |> Spawner.spawn()
```
It becomes:
```elixir
alias Cortex.Provider.CLI, as: ProviderCLI

provider_config = [command: config.command, cwd: config.cwd]
{:ok, handle} = ProviderCLI.start(provider_config)

try do
  ProviderCLI.run(handle, config.prompt, SpawnConfig.to_run_opts(config))
after
  ProviderCLI.stop(handle)
end
```

For Phase 1, internal agents always use `Provider.CLI` (they have no per-agent provider config). The direct reference to `ProviderCLI` is intentional — internal agents don't participate in provider resolution. A helper like `SpawnConfig.to_run_opts/1` extracts the run-time options (team_name, model, max_turns, etc.) from the SpawnConfig struct, excluding the prompt (now a separate argument) and provider-level config (command, cwd).

---

## Architecture / Component Boundaries

### Components I Touch
- **`Runner.Executor`** (`lib/cortex/orchestration/runner/executor.ex`) — the core execution engine. `run_team/6` is the critical function. I replace the direct `Spawner.spawn(spawner_opts)` call with `Provider.Resolver.resolve!/2` + the `start/1` → `run/3` → `stop/1` lifecycle.
- **`Runner`** (`lib/cortex/orchestration/runner.ex`) — may need minor updates to pass provider config through, but currently all config is available in `Executor` via the `Config.t()` struct. Likely no changes needed here.
- **`InternalAgent.Launcher`** (`lib/cortex/internal_agent/launcher.ex`) — update `run/1` to use `Provider.CLI.start/1` → `Provider.CLI.run/3` → `Provider.CLI.stop/1` instead of calling Spawner directly.
- **`InternalAgent.SpawnConfig`** (`lib/cortex/internal_agent/spawn_config.ex`) — add `to_run_opts/1` helper that extracts run-time options (team_name, model, etc.) excluding prompt and provider-level config.

### Components I Create
- **`Provider.Resolver`** (`lib/cortex/provider/resolver.ex`) — pure function module that maps config fields to Provider implementation modules.

### Components I Depend On (Owned by Other Engineers)
- **`Provider` behaviour** (Behaviour Architect) — defines the `start/1`, `run/3`, `stop/1` callbacks
- **`Provider.CLI`** (CLI Refactor Engineer) — wraps existing Spawner, implements Provider behaviour with the 3-callback lifecycle
- **Config changes** (Config Engineer) — `provider` and `backend` fields on `Defaults` and `Team` structs

### How Config Changes Propagate
- Config is parsed once at load time by `Config.Loader`
- The `Config.t()` struct (with `defaults` and `teams`) flows through `Runner` → `Executor`
- `Executor.run_team/6` already has access to both the `Team` struct and `config.defaults`
- The Resolver reads `team.provider` and `defaults.provider` — no new propagation needed

### Concurrency Model
- No change. Each team is still spawned in its own `Task.async` within `execute_tier`. The `start/1` → `run/3` → `stop/1` lifecycle is synchronous within that task, same as `Spawner.spawn/1` today.

### Backpressure
- No change. Tier-based execution provides natural backpressure — all teams in tier N must complete before tier N+1 starts.

---

## Correctness Invariants

1. **Backward compatibility:** With no `provider` field in config, the system dispatches to `Provider.CLI`, which calls `Spawner.spawn/1` — identical to today's behavior.
2. **TeamResult contract preserved:** Every provider returns `{:ok, TeamResult.t()} | {:error, term()}`. The Executor's pattern match on `TeamResult.status` works unchanged.
3. **All three orchestration modes work:** DAG (via Executor), mesh (via Launcher), and gossip (via Launcher) all dispatch through Provider.
4. **Resolver is deterministic:** Given the same Team + Defaults, the resolver always returns the same module. No side effects.
5. **Unknown provider is a clear error:** `{:error, {:unknown_provider, "bogus"}}` — not a crash, not a silent fallback.
6. **Internal agents always use CLI:** InternalAgent.Launcher always resolves to Provider.CLI in Phase 1 (summary agents, debug agents, coordinators don't have provider config).

---

## Tests

### Unit Tests
- **`test/cortex/provider/resolver_test.exs`**
  - `resolve/2` returns `Provider.CLI` when team has no provider field
  - `resolve/2` returns `Provider.CLI` when team has `provider: "cli"`
  - `resolve/2` uses team-level provider over defaults-level provider
  - `resolve/2` falls back to defaults-level provider when team has none
  - `resolve/2` returns `{:error, {:unknown_provider, name}}` for unknown provider string
  - `resolve!/2` raises for unknown provider

### Integration Tests (Updated Existing)
- **`test/cortex/orchestration/runner_test.exs`** — existing runner integration tests continue to pass (they use a mock command, which flows through Provider.CLI → Spawner.spawn as before)
- **`test/cortex/orchestration/runner/executor_test.exs`** — if exists, verify the executor's team spawning still works end-to-end

### Verification of Full Flow
- **`test/cortex/internal_agent/launcher_test.exs`** — verify Launcher still works with the Provider indirection

### Commands
```bash
mix test test/cortex/provider/resolver_test.exs          # resolver unit tests
mix test test/cortex/orchestration/                       # full orchestration suite
mix test                                                  # all tests pass
mix compile --warnings-as-errors                          # no warnings
mix credo --strict                                        # no credo issues
```

---

## Benchmarks + "Success"

N/A — The resolver is a single pattern match (nanoseconds). The Provider.CLI `start/1` → `run/3` → `stop/1` lifecycle is a thin wrapper around `Spawner.spawn/1`, adding two extra function calls of overhead. No measurable performance impact. Existing `bench/agent_bench.exs` should show no regression.

---

## Engineering Decisions & Tradeoffs

### Decision 1: Resolver as a Separate Module vs. Inline Resolution in Executor

- **Decision:** Create `Provider.Resolver` as its own module
- **Alternatives considered:** Inline the resolution logic directly in `Executor.run_team/6` and `Launcher.run/1`
- **Why:** A dedicated module is independently testable, gives a single source of truth for provider resolution, and avoids duplicating resolution logic between Executor and Launcher. It also provides a clean extension point for Phase 2 (adding `Provider.External` resolution).
- **Tradeoff acknowledged:** One more module to maintain. But it's tiny (~30 lines) and the alternative (duplicated inline logic) is worse.

### Decision 2: Split Spawner Opts into provider_config + prompt + run_opts (Matching run/3 Signature)

- **Decision:** Decompose the current flat `spawner_opts` keyword list into three arguments matching the `start/1` → `run/3` → `stop/1` lifecycle: (1) `provider_config` passed to `start/1` (static per-provider config like command path, cwd), (2) `prompt` as the first run-time argument, (3) `run_opts` keyword list for remaining per-run options (team_name, model, max_turns, callbacks, etc.)
- **Alternatives considered:** (a) Keep a single flat keyword list and have each Provider split it internally; (b) Define typed structs for all three arguments
- **Why:** Aligns with the Behaviour Architect's `run(handle, prompt, run_opts)` contract. The split is natural: provider config (command, cwd) belongs at `start/1` time, the prompt is the primary input, and run_opts are per-execution settings. This also makes the API cleaner for future providers — `Provider.External` won't need command/cwd but will need the prompt and team_name.
- **Tradeoff acknowledged:** The Executor's `run_team/6` now has more lines (build provider_config, extract prompt, build run_opts, call start/run/stop) instead of the single `Spawner.spawn(opts)` call. Slightly more code, but the separation of concerns is correct and the `try/after` pattern for `stop/1` is worth the structure.

### Decision 3: InternalAgent.Launcher Always Uses Provider.CLI (No Config-Based Resolution)

- **Decision:** Launcher hardcodes `Provider.CLI` for Phase 1 rather than accepting a provider config field on `SpawnConfig`
- **Alternatives considered:** Add an optional `provider` field to `SpawnConfig` and resolve dynamically
- **Why:** Internal agents (summary, debug, coordinator) are always local `claude -p` processes. Adding provider config to SpawnConfig would be premature — no internal agent use case requires non-CLI providers. The pattern match through Provider.CLI still establishes the indirection for future change.
- **Tradeoff acknowledged:** If someone later wants an internal agent on a remote backend, they'll need to update Launcher. But that's an unlikely Phase 1 requirement.

---

## Risks & Mitigations

### Risk 1: Provider.CLI Implementation Doesn't Match start/run/stop Lifecycle
- **Risk:** The CLI Refactor Engineer's `Provider.CLI` implementation of `start/1`, `run/3`, `stop/1` doesn't align with how I'm splitting the current `spawner_opts` (e.g., `start/1` expects different config keys, or `run/3` expects `run_opts` in a different shape)
- **Impact:** Executor and Launcher calls to Provider.CLI fail at runtime; tests break
- **Mitigation:** Coordinate with CLI Refactor Engineer on the exact split of `spawner_opts` into `provider_config` (start) vs `run_opts` (run). Validate by reading the Provider.CLI module before writing Executor changes. The natural split: `start/1` gets `[command: ..., cwd: ...]`, `run/3` gets `(handle, prompt, [team_name: ..., model: ..., max_turns: ..., ...])`.
- **Validation time:** < 5 minutes — read Provider.CLI module and confirm arg expectations

### Risk 2: Config Struct Fields Not Yet Available
- **Risk:** The Config Engineer hasn't added `provider` field to `Team` and `Defaults` structs when I start implementation
- **Impact:** Resolver can't read `team.provider` or `defaults.provider`; tests fail on struct access
- **Mitigation:** Implement Resolver to handle both cases: (a) field exists and is populated, (b) field doesn't exist (use `Map.get/3` with default `nil` until the struct is updated). Alternatively, sequence my work after the Config Engineer's PR.
- **Validation time:** < 5 minutes — check if the struct has the field

### Risk 3: Breaking Existing Tests by Changing the Spawner Call Path
- **Risk:** Existing tests mock or stub `Spawner.spawn/1` directly. Routing through Provider.CLI means those mocks no longer intercept the call.
- **Impact:** Tests pass but aren't actually testing what they think; or tests fail because the mock isn't hit
- **Mitigation:** Run `mix test` after every change. Existing tests use a mock script via the `:command` option — that flows through to `Spawner.spawn/1` regardless of whether the call comes from Executor directly or via Provider.CLI. The mock script is at the OS process level, not the Elixir function level, so the indirection is transparent.
- **Validation time:** < 10 minutes — run full test suite

### Risk 4: Circular Dependency Between Provider.Resolver and Provider.CLI
- **Risk:** Resolver imports Provider.CLI; CLI imports Spawner; if Spawner somehow needed Resolver, we'd have a cycle
- **Impact:** Compilation error
- **Mitigation:** Resolver only returns module atoms — it doesn't call or import any Provider module. The actual `provider.run(opts)` call happens in Executor, not in Resolver. No cycle possible.
- **Validation time:** < 2 minutes — `mix compile --warnings-as-errors`

---

## Recommended API Surface

### `Cortex.Provider.Resolver`

| Function | Spec | Behaviour |
|----------|------|-----------|
| `resolve/2` | `(Team.t(), Defaults.t()) -> {:ok, module()} \| {:error, term()}` | Resolve provider module from config |
| `resolve!/2` | `(Team.t(), Defaults.t()) -> module()` | Bang variant, raises on error |

### Modified Functions (No Public Signature Changes)

| Module | Function | Change |
|--------|----------|--------|
| `Executor` | `run_team/6` (private) | Replace `Spawner.spawn(spawner_opts)` with `resolve! → start/1 → run/3 → stop/1` lifecycle. Split current `spawner_opts` into `provider_config`, `prompt`, and `run_opts`. |
| `Launcher` | `run/1` | Replace `Spawner.spawn(opts)` with `Provider.CLI.start/1 → run/3 → stop/1` lifecycle. |
| `SpawnConfig` | `to_run_opts/1` (new) | Extract run-time options (team_name, model, max_turns, etc.) from SpawnConfig, excluding prompt and provider-level config. Complements existing `to_spawner_opts/1`. |

---

## Folder Structure

```
lib/cortex/provider/
├── resolver.ex           # NEW — Provider.Resolver (this role)
├── cli.ex                # CLI Refactor Engineer
├── ...                   # Future providers (Phase 2+)

lib/cortex/orchestration/
├── runner.ex             # No changes expected
├── runner/
│   ├── executor.ex       # MODIFY — run_team/6 dispatches via Resolver
│   ├── outcomes.ex       # No changes
│   ├── reconciler.ex     # No changes
│   └── store.ex          # No changes

lib/cortex/internal_agent/
├── launcher.ex           # MODIFY — dispatch via Provider.CLI start/run/stop lifecycle
├── spawn_config.ex       # MODIFY — add to_run_opts/1 helper

test/cortex/provider/
├── resolver_test.exs     # NEW — Resolver unit tests
```

---

## Step-by-Step Task Plan

### Task 1: Create Provider.Resolver Module
- **Outcome:** `Provider.Resolver.resolve/2` and `resolve!/2` exist, tested, compile clean
- **Files to create:** `lib/cortex/provider/resolver.ex`, `test/cortex/provider/resolver_test.exs`
- **Verification:**
  ```bash
  mix test test/cortex/provider/resolver_test.exs
  mix compile --warnings-as-errors
  mix credo --strict
  ```
- **Commit message:** `feat(provider): add Provider.Resolver for config-based provider dispatch`

### Task 2: Wire Executor.run_team to Dispatch via Provider Lifecycle
- **Outcome:** `Executor.run_team/6` resolves the provider module via `Provider.Resolver.resolve!/2`, then calls `start/1` → `run/3` → `stop/1` instead of `Spawner.spawn(spawner_opts)`. The current `spawner_opts` is decomposed into `provider_config` (command, cwd), `prompt` (already built by Injection), and `run_opts` (team_name, model, max_turns, callbacks, etc.). A `try/after` block ensures `stop/1` is always called.
- **Files to modify:** `lib/cortex/orchestration/runner/executor.ex`
- **Verification:**
  ```bash
  mix test test/cortex/orchestration/
  mix test
  mix compile --warnings-as-errors
  ```
- **Commit message:** `refactor(executor): dispatch team spawning through Provider start/run/stop lifecycle`

### Task 3: Wire InternalAgent.Launcher to Dispatch via Provider Lifecycle
- **Outcome:** `Launcher.run/1` calls `Provider.CLI.start/1` → `Provider.CLI.run/3` → `Provider.CLI.stop/1` instead of `Spawner.spawn(opts)`. Add `SpawnConfig.to_run_opts/1` helper to extract run-time options (team_name, model, max_turns, callbacks) excluding prompt and provider-level config.
- **Files to modify:** `lib/cortex/internal_agent/launcher.ex`, `lib/cortex/internal_agent/spawn_config.ex`
- **Verification:**
  ```bash
  mix test test/cortex/internal_agent/
  mix test
  mix compile --warnings-as-errors
  ```
- **Commit message:** `refactor(launcher): dispatch through Provider.CLI start/run/stop lifecycle`

### Task 4: Update/Add Integration Tests for Full Flow
- **Outcome:** Tests explicitly verify the Provider dispatch path works end-to-end for DAG execution
- **Files to modify:** Existing orchestration tests as needed; possibly add a test that asserts Provider.Resolver is called
- **Verification:**
  ```bash
  mix test
  mix credo --strict
  mix format --check-formatted
  ```
- **Commit message:** `test(integration): verify orchestration flow through Provider abstraction`

### Task 5: Final Validation — Full Suite + Linting
- **Outcome:** All tests pass, no warnings, credo clean, format clean
- **Files to modify:** None (fix-up only if prior tasks left issues)
- **Verification:**
  ```bash
  mix format
  mix compile --warnings-as-errors
  mix credo --strict
  mix test
  ```
- **Commit message:** `chore: final lint and format pass for integration engineer changes`

---

## CLAUDE.md Contributions (Do NOT Write the File; Propose Content)

### From Integration Engineer

**Coding style rules:**
- When adding a new Provider implementation, register it in `Provider.Resolver.provider_module/1` — this is the single source of truth for provider name → module mapping.
- Provider implementations must return `{:ok, TeamResult.t()} | {:error, term()}` from their `run/3` callback. Do not return raw maps or other shapes.

**Dev commands:**
```bash
mix test test/cortex/provider/          # provider + resolver tests
mix test test/cortex/orchestration/     # full orchestration suite
```

**Before you commit checklist:**
- [ ] `Provider.Resolver` handles the new provider string if you added one
- [ ] All three orchestration modes (DAG, mesh, gossip) still work — run full test suite
- [ ] No direct `Spawner.spawn/1` calls outside of `Provider.CLI` — the abstraction boundary must hold

**Guardrails:**
- Do NOT call `Spawner.spawn/1` or `Spawner.resume/1` from orchestration code. All spawning must go through a Provider module. The only module allowed to call Spawner directly is `Provider.CLI`.

---

## EXPLAIN.md Contributions (Do NOT Write the File; Propose Outline Bullets)

### Flow / Architecture Explanation
- The orchestration layer (Runner.Executor, InternalAgent.Launcher) never calls Spawner directly. Instead, it resolves a Provider module via `Provider.Resolver` and drives the `start/1` → `run/3` → `stop/1` lifecycle.
- `Provider.Resolver.resolve/2` reads the `provider` field from the Team struct (with fallback to Defaults, then to `"cli"`), and returns the corresponding module (e.g., `Provider.CLI`).
- `start/1` initializes the provider with config (command path, cwd); `run/3` executes with (handle, prompt, run_opts); `stop/1` cleans up.
- Provider.CLI wraps the existing Spawner — it's a thin lifecycle wrapper that preserves all current behavior.

### Key Engineering Decisions + Tradeoffs
- The current flat `spawner_opts` keyword list is split into three parts matching the Provider lifecycle: provider_config (start), prompt (first arg to run), and run_opts (second arg to run). This aligns with the Behaviour Architect's API.
- Internal agents (summary, debug, coordinator) always use Provider.CLI — they don't participate in provider config resolution.
- Resolver is a separate module (not inline in Executor) for testability and to avoid duplicating resolution logic.

### Limits of MVP + Next Steps
- Phase 1 only has one provider (CLI). The Resolver is trivially simple now but provides the extension point for Phase 2 (`Provider.External`).
- SpawnBackend resolution is not wired in Phase 1 — the backend is always Local. Backend resolution will follow the same Resolver pattern in Phase 3.

### How to Run Locally + How to Validate
- `mix test` — all existing tests pass through the new Provider dispatch path
- `mix test test/cortex/provider/resolver_test.exs` — Resolver unit tests
- Manually: run an orchestration via `mix run` or the dashboard; observe that behavior is identical

---

## READY FOR APPROVAL
