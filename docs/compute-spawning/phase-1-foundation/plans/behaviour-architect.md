# Behaviour Architect — Phase 1 Foundation Plan

## You are in PLAN MODE.

### Project
I want to do a **compute spawning abstraction layer for Cortex**.

**Goal:** build **Provider and SpawnBackend behaviours** in which we **decouple LLM communication from compute placement, enabling the orchestration layer to dispatch work through a unified interface regardless of whether agents run locally, in Docker, or on Kubernetes**.

### Role + Scope
- **Role:** Behaviour Architect
- **Scope:** Define the `Cortex.Provider` and `Cortex.SpawnBackend` behaviour modules — typespecs, callbacks, documentation, and behaviour contract tests. I do NOT own the implementations (CLI Refactor Engineer), config changes (Config Engineer), or orchestration wiring (Integration Engineer).
- **File you will write:** `docs/compute-spawning/phase-1-foundation/plans/behaviour-architect.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** Define a `Cortex.Provider` behaviour with callbacks for starting, running (sync), streaming (async/events), and stopping an LLM provider session.
- **FR2:** Define a `Cortex.SpawnBackend` behaviour with callbacks for spawning, streaming output from, stopping, and checking the status of a compute process.
- **FR3:** Both behaviours must define opaque handle types so implementations control their own internal state (e.g., port refs, HTTP connection pids, K8s Job refs).
- **FR4:** The Provider behaviour's result type must be compatible with the existing `TeamResult` struct — the return from `run/3` must yield data that can construct a `TeamResult` without loss.
- **FR5:** The Provider behaviour must include a `stream/3` callback that returns a stream of typed events (token updates, activity notifications, session init, result) — matching the callback-based events the Spawner already emits.
- **FR6:** Both behaviours must include `@optional_callbacks` where appropriate so that minimal implementations (e.g., a test mock) don't need to implement every callback.
- Tests required: behaviour contract tests using `Mox` to verify that any conforming implementation satisfies the type contracts.
- Metrics required: N/A for behaviours — telemetry integration is the Integration Engineer's scope.

## Non-Functional Requirements
- Language/runtime: Elixir 1.16+, Erlang/OTP 26+
- Local dev: `mix test test/cortex/provider_test.exs test/cortex/spawn_backend_test.exs`
- Observability: N/A for behaviour definitions (implementations emit telemetry)
- Safety: behaviours enforce return types via `@spec`; invalid returns will produce dialyzer warnings in implementations
- Documentation: `@moduledoc`, `@doc`, `@spec` on every callback; examples in moduledoc
- Performance: N/A — behaviours are compile-time contracts with zero runtime overhead

---

## Assumptions / System Model
- Deployment environment: behaviours are pure compile-time contracts; no runtime dependency on Docker, K8s, or network
- Failure modes: each implementation is responsible for its own error handling; behaviours define the `{:error, term()}` contract shape
- Delivery guarantees: N/A — behaviours don't transport data
- Multi-tenancy: N/A for MVP

---

## Data Model

### Provider Types

- **`Cortex.Provider.config()`** — map with provider-specific configuration:
  ```
  %{
    provider: atom(),          # e.g., :cli, :http, :external
    model: String.t(),
    max_turns: pos_integer(),
    permission_mode: String.t(),
    timeout_minutes: pos_integer(),
    # Implementation-specific keys allowed
    ...
  }
  ```

- **`Cortex.Provider.handle()`** — opaque, implementation-defined. For CLI this will be a port reference wrapper; for HTTP it will be a connection pid; for External it will be a Gateway agent reference.

- **`Cortex.Provider.event()`** — tagged union for streaming events:
  ```
  {:token_update, team_name :: String.t(), tokens :: map()}
  | {:activity, team_name :: String.t(), activity :: map()}
  | {:session_started, team_name :: String.t(), session_id :: String.t()}
  | {:result, TeamResult.t()}
  | {:error, term()}
  ```

- **`Cortex.Provider.run_opts()`** — keyword list passed to `run/3` and `stream/3`:
  ```
  [
    team_name: String.t(),        # required
    prompt: String.t(),           # required
    log_path: String.t() | nil,
    cwd: String.t() | nil,
    session_id: String.t() | nil  # for resume
  ]
  ```

### SpawnBackend Types

- **`Cortex.SpawnBackend.config()`** — map with backend-specific configuration:
  ```
  %{
    backend: atom(),           # e.g., :local, :docker, :k8s
    command: String.t(),       # for local: "claude"
    cwd: String.t() | nil,
    # Implementation-specific keys allowed
    ...
  }
  ```

- **`Cortex.SpawnBackend.handle()`** — opaque, implementation-defined. For Local this will be `{port(), os_pid :: non_neg_integer()}`. For Docker: container ID. For K8s: Pod name + namespace.

- **`Cortex.SpawnBackend.status()`** — `:running | :done | :failed`

### Validation Rules
- `config()` maps must contain a `:provider` or `:backend` key identifying the implementation
- `handle()` is fully opaque — no cross-implementation assumptions
- `event()` tuples are tagged so consumers can pattern-match without knowing the provider

### Versioning Strategy
- Behaviours are versioned implicitly by their callback list. Adding a callback is a breaking change unless marked `@optional_callbacks`. All Phase 2+ callbacks (e.g., `resume/2`) will be optional.

---

## APIs

### Provider Behaviour — `Cortex.Provider`

```elixir
@callback start(config :: config()) :: {:ok, handle()} | {:error, term()}
```
Initialize provider resources. For CLI: resolve command path, validate model. For HTTP: establish connection pool. For External: verify Gateway connectivity.

```elixir
@callback run(handle :: handle(), prompt :: String.t(), opts :: run_opts()) ::
            {:ok, TeamResult.t()} | {:error, term()}
```
Synchronous execution. Sends prompt, blocks until completion, returns a `TeamResult`. This is what `Runner.Executor.run_team/6` will call.

```elixir
@callback stream(handle :: handle(), prompt :: String.t(), opts :: run_opts()) ::
            {:ok, Enumerable.t(event())} | {:error, term()}
```
Streaming execution. Returns a lazy enumerable of `event()` tuples. Consumers can `Enum.each/2` for side effects (broadcasting token updates, activity) or collect the final `:result` event. Optional callback — implementations that don't support streaming can omit it and callers fall back to `run/3`.

```elixir
@callback stop(handle :: handle()) :: :ok
```
Release provider resources. Idempotent.

```elixir
@callback resume(handle :: handle(), session_id :: String.t(), opts :: run_opts()) ::
            {:ok, TeamResult.t()} | {:error, term()}
```
Resume a previous session. Optional callback — only `Provider.CLI` supports this initially.

### SpawnBackend Behaviour — `Cortex.SpawnBackend`

```elixir
@callback spawn(config :: config()) :: {:ok, handle()} | {:error, term()}
```
Start the compute process (Erlang port, Docker container, K8s Pod). Returns an opaque handle.

```elixir
@callback stream(handle :: handle()) :: {:ok, Enumerable.t(binary())} | {:error, term()}
```
Get the raw output stream from the compute process. Returns a lazy enumerable of binary chunks. The Provider implementation is responsible for parsing these into structured events.

```elixir
@callback stop(handle :: handle()) :: :ok
```
Terminate the compute process. Idempotent. For local: `Port.close/1`. For Docker: `docker stop`. For K8s: delete Pod.

```elixir
@callback status(handle :: handle()) :: status()
```
Poll current status. Implementations should be non-blocking.

### Error Semantics
- All fallible callbacks return `{:ok, value} | {:error, reason}` where `reason` is an atom or a descriptive tuple
- `stop/1` always returns `:ok` — stopping an already-stopped handle is a no-op
- `status/1` returns `:failed` if the handle refers to a dead process — never raises

---

## Architecture / Component Boundaries

### Components I Own
- **`lib/cortex/provider.ex`** — Provider behaviour module with `@callback` definitions, type specs, `@optional_callbacks`, and a `__using__` macro that injects `@behaviour Cortex.Provider`
- **`lib/cortex/spawn_backend.ex`** — SpawnBackend behaviour module with the same structure
- **`test/cortex/provider_test.exs`** — contract tests using Mox
- **`test/cortex/spawn_backend_test.exs`** — contract tests using Mox

### Components I Do NOT Own
- `Provider.CLI` / `SpawnBackend.Local` implementations — CLI Refactor Engineer
- Config schema changes — Config Engineer
- `Runner.Executor` wiring — Integration Engineer

### How These Compose

The Provider and SpawnBackend are independent behaviours that compose at the implementation level, not the behaviour level:

```
Runner.Executor
  └── calls Provider.run/3
        └── Provider.CLI internally uses SpawnBackend.Local
        └── Provider.External internally uses Gateway (no SpawnBackend)
        └── Provider.HTTP manages its own HTTP connection (no SpawnBackend)
```

Provider.CLI is the only Phase 1 provider that composes with a SpawnBackend. The composition happens inside the implementation — the behaviour contracts don't reference each other. This keeps each behaviour focused and independently testable.

### Concurrency Model
- Behaviours impose no concurrency model — implementations choose their own
- Provider.CLI will be synchronous (blocking `receive` loop, matching current Spawner)
- Provider.HTTP (future) will be async with GenServer
- SpawnBackend.Local will be synchronous port I/O

---

## Correctness Invariants

1. **Any module implementing `@behaviour Cortex.Provider`** compiles only if it defines all required callbacks (`start/1`, `run/3`, `stop/1`).
2. **Any module implementing `@behaviour Cortex.SpawnBackend`** compiles only if it defines all required callbacks (`spawn/1`, `stream/1`, `stop/1`, `status/1`).
3. **`Provider.run/3` always returns `{:ok, TeamResult.t()} | {:error, term()}`** — the result type is pinned to `TeamResult` so the orchestration layer never needs to translate.
4. **`SpawnBackend.stop/1` is idempotent** — calling it on an already-stopped handle returns `:ok` without side effects.
5. **`Provider.stream/3` events are tagged tuples** — consumers can pattern-match without knowing the implementation.
6. **Optional callbacks do not break existing implementations** — `resume/2` and `stream/3` are `@optional_callbacks`; modules that omit them still compile.
7. **Handle opacity is enforced** — no behaviour-level code inspects handle internals; only the originating implementation touches them.

---

## Tests

### Unit Tests

**`test/cortex/provider_test.exs`**
- Mox-based: define `Cortex.MockProvider` implementing `Cortex.Provider`
- Test that `start/1` → `run/3` → `stop/1` lifecycle works with mock expectations
- Test that `run/3` returns `{:ok, %TeamResult{}}` with correct fields
- Test that `run/3` returns `{:error, reason}` on failure
- Test that `stream/3` returns an enumerable of correctly-tagged events
- Test that `stop/1` is idempotent (can be called twice)
- Test that `resume/2` is optional (mock without it still compiles)

**`test/cortex/spawn_backend_test.exs`**
- Mox-based: define `Cortex.MockSpawnBackend` implementing `Cortex.SpawnBackend`
- Test that `spawn/1` → `stream/1` → `stop/1` lifecycle works
- Test that `status/1` returns `:running`, `:done`, or `:failed`
- Test that `stop/1` is idempotent
- Test that `stream/1` returns an enumerable of binaries

### Commands
```bash
mix test test/cortex/provider_test.exs
mix test test/cortex/spawn_backend_test.exs
mix test test/cortex/provider_test.exs test/cortex/spawn_backend_test.exs --trace
```

### Property/Fuzz Tests
N/A — behaviours are compile-time contracts; property testing applies to implementations.

### Failure Injection Tests
N/A — the behaviour definitions don't execute. Implementation-level failure tests are owned by the CLI Refactor Engineer.

---

## Benchmarks + "Success"

N/A — behaviours are compile-time constructs with zero runtime overhead. There is nothing to benchmark. Success is measured by:
1. Both behaviour modules compile without warnings
2. `mix dialyzer` passes with the new modules
3. All Mox-based contract tests pass
4. The CLI Refactor Engineer can implement `Provider.CLI` and `SpawnBackend.Local` against these behaviours without needing changes

---

## Engineering Decisions & Tradeoffs

### Decision 1: Provider.run/3 returns TeamResult directly (not a generic map)

- **Alternatives considered:**
  - Return a generic map and let the orchestration layer construct `TeamResult`
  - Return a `Provider.Result` struct that `TeamResult` wraps
- **Why:** The orchestration layer (`Runner.Executor`) already expects `TeamResult`. Returning it directly from the Provider eliminates a translation layer and keeps the integration surface minimal. Every Provider implementation must understand what a successful run looks like in Cortex terms.
- **Tradeoff acknowledged:** Provider implementations are coupled to `Cortex.Orchestration.TeamResult`. If `TeamResult` changes, all providers need updating. This is acceptable because `TeamResult` is a stable core struct and providers are internal to Cortex.

### Decision 2: SpawnBackend.stream/1 returns raw binary chunks, not parsed events

- **Alternatives considered:**
  - SpawnBackend returns parsed NDJSON events
  - SpawnBackend returns `Provider.event()` tuples
- **Why:** Parsing is the Provider's responsibility, not the backend's. A Docker or K8s backend shouldn't know about NDJSON or Claude's output format — it just forwards bytes. This keeps SpawnBackend focused on compute lifecycle (start/stop/stream bytes) and Provider focused on LLM protocol (parse/interpret/structure).
- **Tradeoff acknowledged:** Provider.CLI must contain parsing logic even though SpawnBackend.Local could theoretically parse lines. This creates a small amount of code in Provider.CLI that duplicates awareness of the Spawner's NDJSON format, but it maintains clean separation of concerns.

### Decision 3: stream/3 and resume/2 as @optional_callbacks

- **Alternatives considered:**
  - Make all callbacks required
  - Use separate behaviour modules (e.g., `Cortex.Provider.Streamable`)
- **Why:** Not all providers support streaming (e.g., a synchronous HTTP provider might only support `run/3`). Not all providers support session resume (only CLI does today). Making these optional keeps the required callback set minimal while allowing implementations to opt in. Separate behaviour modules would complicate the dispatch logic in the Integration Engineer's code.
- **Tradeoff acknowledged:** Callers must check `function_exported?/3` before calling optional callbacks, adding a small runtime check. This is preferable to requiring all implementations to stub methods they can't meaningfully implement.

### Decision 4: No `__using__` macro — plain `@behaviour` attribute

- **Alternatives considered:**
  - Provide `use Cortex.Provider` macro that injects `@behaviour`, default implementations, and helper functions
- **Why:** `@behaviour` is the idiomatic Elixir approach. A `__using__` macro adds indirection, makes it harder to see what's injected, and can conflict with other macros. The Cortex codebase already uses plain `@behaviour` (see `Cortex.Tool.Behaviour`). Following the established pattern.
- **Tradeoff acknowledged:** Implementations can't inherit default `stop/1` (no-op) or helper functions. Each implementation must write its own, but this is trivial (1-2 lines) and keeps the contract explicit.

---

## Risks & Mitigations

### Risk 1: TeamResult coupling makes the Provider behaviour too rigid for future providers

- **Impact:** If a future provider (e.g., HTTP with multi-turn agentic loop) produces results that don't map cleanly to TeamResult fields, we'd need to change the behaviour.
- **Mitigation:** TeamResult already has `nil`-able fields for all non-essential data (cost, tokens, duration, session_id). A provider that doesn't have some of these can return `nil`. Validate by checking that the HTTP provider use case (multi-turn, no session_id, different cost model) can produce a valid TeamResult.
- **Validation time:** 5 minutes — enumerate TeamResult fields against the HTTP provider's expected output.

### Risk 2: Mox dependency for tests may conflict with existing test setup

- **Impact:** If the project doesn't already use Mox, adding it creates a new dependency. If it does, mock names might collide.
- **Mitigation:** Check `mix.exs` for Mox dependency. If absent, add it to `:test`-only deps. Use namespaced mock names (`Cortex.MockProvider`, `Cortex.MockSpawnBackend`) to avoid collisions.
- **Validation time:** 2 minutes — `grep Mox mix.exs`.

### Risk 3: SpawnBackend.stream/1 returning Enumerable.t() may not work for all backends

- **Impact:** Docker and K8s backends may need to poll logs rather than receive a push stream. An `Enumerable.t()` that blocks on `Enum.next` could tie up a process.
- **Mitigation:** `Stream.resource/3` handles this pattern well — it can wrap a polling loop as a lazy enumerable. Document this pattern in the SpawnBackend moduledoc. The Local implementation wraps the port's `receive` loop as a Stream.
- **Validation time:** 5 minutes — write a pseudocode `Stream.resource/3` for a polling Docker log tail.

### Risk 4: Optional callbacks may cause confusing runtime errors when callers forget to check

- **Impact:** Calling `Provider.resume/2` on an implementation that doesn't define it raises `UndefinedFunctionError` at runtime, not compile time.
- **Mitigation:** Document the pattern in the Provider moduledoc. The Integration Engineer's dispatch code should use `function_exported?(module, :resume, 2)` before calling. Add a helper function `Cortex.Provider.supports_resume?/1` that wraps this check.
- **Validation time:** 3 minutes — verify `function_exported?/3` works with Mox mocks.

---

## Recommended API Surface

### `Cortex.Provider` — 5 callbacks (3 required, 2 optional)

| Callback | Required | Signature | Returns |
|----------|----------|-----------|---------|
| `start/1` | Yes | `start(config())` | `{:ok, handle()} \| {:error, term()}` |
| `run/3` | Yes | `run(handle(), String.t(), run_opts())` | `{:ok, TeamResult.t()} \| {:error, term()}` |
| `stop/1` | Yes | `stop(handle())` | `:ok` |
| `stream/3` | No | `stream(handle(), String.t(), run_opts())` | `{:ok, Enumerable.t(event())} \| {:error, term()}` |
| `resume/2` | No | `resume(handle(), run_opts())` | `{:ok, TeamResult.t()} \| {:error, term()}` |

Helper functions (not callbacks):
- `supports_stream?/1` — checks if module implements `stream/3`
- `supports_resume?/1` — checks if module implements `resume/2`

### `Cortex.SpawnBackend` — 4 callbacks (all required)

| Callback | Signature | Returns |
|----------|-----------|---------|
| `spawn/1` | `spawn(config())` | `{:ok, handle()} \| {:error, term()}` |
| `stream/1` | `stream(handle())` | `{:ok, Enumerable.t(binary())} \| {:error, term()}` |
| `stop/1` | `stop(handle())` | `:ok` |
| `status/1` | `status(handle())` | `status()` |

---

## Folder Structure

```
lib/cortex/
├── provider.ex                    # Provider behaviour (NEW — I own this)
├── spawn_backend.ex               # SpawnBackend behaviour (NEW — I own this)
├── provider/
│   ├── cli.ex                     # CLI Refactor Engineer owns
│   ├── external.ex                # Phase 2 — External Provider Engineer owns
│   └── http.ex                    # Future work
├── spawn_backend/
│   ├── local.ex                   # CLI Refactor Engineer owns
│   ├── docker.ex                  # Phase 3 — Docker Backend Engineer owns
│   └── k8s.ex                     # Phase 3 — K8s Backend Engineer owns
├── orchestration/
│   ├── spawner.ex                 # Existing — preserved, wrapped by Provider.CLI
│   ├── runner/
│   │   └── executor.ex            # Integration Engineer rewires this
│   └── team_result.ex             # Existing — no changes needed
└── ...

test/cortex/
├── provider_test.exs              # Behaviour contract tests (NEW — I own this)
├── spawn_backend_test.exs         # Behaviour contract tests (NEW — I own this)
├── provider/
│   └── cli_test.exs               # CLI Refactor Engineer owns
├── spawn_backend/
│   └── local_test.exs             # CLI Refactor Engineer owns
└── ...
```

---

## Step-by-Step Task Plan

### Task 1: Create `Cortex.Provider` behaviour module
- Create `lib/cortex/provider.ex`
- Define `@type config()`, `@type handle()`, `@type event()`, `@type run_opts()`, `@type status()`
- Define 5 `@callback` declarations with `@doc` and `@spec`
- Mark `stream/3` and `resume/2` as `@optional_callbacks`
- Add `supports_stream?/1` and `supports_resume?/1` helper functions
- Add comprehensive `@moduledoc` with usage examples
- **Verify:** `mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict`
- **Commit:** `feat(provider): define Provider behaviour with start/run/stream/stop/resume callbacks`

### Task 2: Create `Cortex.SpawnBackend` behaviour module
- Create `lib/cortex/spawn_backend.ex`
- Define `@type config()`, `@type handle()`, `@type status()`
- Define 4 `@callback` declarations with `@doc` and `@spec`
- Add comprehensive `@moduledoc` with usage examples
- **Verify:** `mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict`
- **Commit:** `feat(spawn_backend): define SpawnBackend behaviour with spawn/stream/stop/status callbacks`

### Task 3: Add Mox dependency (if needed) and define mocks
- Check `mix.exs` for existing Mox dependency; add to `:test` deps if missing
- Define `Cortex.MockProvider` and `Cortex.MockSpawnBackend` in `test/support/mocks.ex` (or `test_helper.exs`)
- **Verify:** `mix deps.get && mix compile --warnings-as-errors`
- **Commit:** `chore(test): add Mox and define mock modules for Provider and SpawnBackend`

### Task 4: Write Provider behaviour contract tests
- Create `test/cortex/provider_test.exs`
- Test `start/1` → `run/3` → `stop/1` lifecycle with mock
- Test `run/3` returns well-formed `TeamResult`
- Test `run/3` error path
- Test `stream/3` returns enumerable of tagged events
- Test `stop/1` idempotency
- Test `supports_stream?/1` and `supports_resume?/1` helpers
- **Verify:** `mix test test/cortex/provider_test.exs --trace`
- **Commit:** `test(provider): add Mox-based contract tests for Provider behaviour`

### Task 5: Write SpawnBackend behaviour contract tests
- Create `test/cortex/spawn_backend_test.exs`
- Test `spawn/1` → `stream/1` → `stop/1` lifecycle
- Test `status/1` returns valid atoms
- Test `stop/1` idempotency
- **Verify:** `mix test test/cortex/spawn_backend_test.exs --trace`
- **Commit:** `test(spawn_backend): add Mox-based contract tests for SpawnBackend behaviour`

### Task 6: Verify full suite and cross-check with existing tests
- Run full test suite to ensure no regressions
- Run dialyzer to verify type correctness
- **Verify:** `mix test && mix dialyzer`
- **Commit:** N/A (verification only, no code changes)

---

## Benchmarks + "Success" Criteria

N/A for behaviour definitions. Success is:
1. `mix compile --warnings-as-errors` passes
2. `mix credo --strict` passes
3. `mix dialyzer` passes (no new warnings)
4. All new tests pass (`mix test test/cortex/provider_test.exs test/cortex/spawn_backend_test.exs`)
5. All existing tests still pass (`mix test`)
6. CLI Refactor Engineer can implement against the behaviours without needing changes

---

## CLAUDE.md contributions (do NOT write the file; propose content)

### From Behaviour Architect

#### Coding Style
- Provider and SpawnBackend implementations must `@behaviour Cortex.Provider` or `@behaviour Cortex.SpawnBackend`
- Handle types are opaque — never pattern-match on another implementation's handle
- All Provider callbacks return `{:ok, value} | {:error, reason}` except `stop/1` which returns `:ok`
- Use `Cortex.Provider.supports_stream?/1` and `supports_resume?/1` before calling optional callbacks

#### Dev Commands
```bash
mix test test/cortex/provider_test.exs          # Provider contract tests
mix test test/cortex/spawn_backend_test.exs      # SpawnBackend contract tests
```

#### Before You Commit (additions)
- If adding a new Provider or SpawnBackend callback, check all implementations
- If modifying Provider.event() types, update all stream consumers
- Run `mix dialyzer` after behaviour changes (catches missing implementations)

#### Guardrails
- Do not add required callbacks to Provider or SpawnBackend without updating ALL existing implementations
- Adding optional callbacks is safe; adding required ones is a breaking change
- Never expose handle internals outside the implementing module

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture
- Provider behaviour abstracts LLM communication; SpawnBackend abstracts compute placement
- These two concerns are orthogonal: Provider.CLI composes with SpawnBackend.Local, but Provider.External uses Gateway directly (no SpawnBackend)
- The orchestration layer (`Runner.Executor`) calls Provider.run/3 — it never touches SpawnBackend directly
- Provider implementations may internally use a SpawnBackend, but this is an implementation detail

### Key Engineering Decisions + Tradeoffs
- Provider.run/3 returns TeamResult directly to avoid a translation layer; tradeoff is coupling providers to TeamResult
- SpawnBackend.stream/1 returns raw bytes, not parsed events; tradeoff is parsing duplication but maintains clean separation
- stream/3 and resume/2 are optional callbacks; tradeoff is runtime `function_exported?` checks

### Limits of MVP + Next Steps
- Phase 1 only has Provider.CLI + SpawnBackend.Local (wrapping existing Spawner)
- Provider.External (Phase 2) and SpawnBackend.Docker/K8s (Phase 3) follow the same behaviour contracts
- Provider.HTTP (Claude Messages API) is future work, independent of compute spawning

### How to Run Locally + Validate
```bash
mix test test/cortex/provider_test.exs test/cortex/spawn_backend_test.exs --trace
mix dialyzer  # verify type contracts
```

---

## READY FOR APPROVAL
