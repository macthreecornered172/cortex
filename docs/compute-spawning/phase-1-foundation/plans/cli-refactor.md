# CLI Refactor Plan — Provider.CLI + SpawnBackend.Local

## You are in PLAN MODE.

### Project
I want to do a **compute abstraction refactor for Cortex**.

**Goal:** build a **Provider + SpawnBackend abstraction layer** in which we **wrap the existing `Spawner` module into `Provider.CLI` + `SpawnBackend.Local` implementations without breaking any existing functionality, enabling future providers (External) and backends (Docker, K8s) to be added behind the same interfaces**.

### Role + Scope (fill in)
- **Role:** CLI Refactor Engineer
- **Scope:** I own the implementation of `Provider.CLI` and `SpawnBackend.Local`, plus refactoring the existing `Spawner` into a thin facade that delegates to these new modules. I do NOT own the behaviour definitions themselves (Behaviour Architect), config schema changes (Config Engineer), or wiring the orchestration layer to use Provider instead of Spawner (Integration Engineer).
- **File I will write:** `docs/compute-spawning/phase-1-foundation/plans/cli-refactor.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** `SpawnBackend.Local` extracts the Erlang port management from `Spawner` — port opening (`open_port/3`), stdin/stdout handling, process monitoring (`port_alive?/1`), timeout killing (`kill_port/1`), and port cleanup.
- **FR2:** `Provider.CLI` implements the Provider behaviour, delegating process management to `SpawnBackend.Local`. It owns the NDJSON parsing pipeline (`parse_ndjson_line/3`, `extract_lines/1`, `collect_output/6`), token accumulation, activity extraction, log file writing, and `TeamResult` construction.
- **FR3:** `Provider.CLI` exposes `start/1`, `run/3`, and `stop/1` (or the equivalent callbacks defined by the Behaviour Architect). `run/3` replaces the current `Spawner.spawn/1` and `Spawner.resume/1` flows.
- **FR4:** The existing `Spawner` module is preserved as a thin facade that delegates `spawn/1` and `resume/1` to `Provider.CLI`, and `extract_session_id_from_log/1` stays in `Spawner` (it reads files, not provider-specific).
- **FR5:** All 13 existing `SpawnerTest` test cases continue to pass without modification.
- **Tests required:** Unit tests for `Provider.CLI` (NDJSON parsing, token accumulation, result construction) and `SpawnBackend.Local` (port lifecycle, timeout, cleanup). Integration tests via the existing `SpawnerTest` suite (unchanged).
- **Metrics required:** N/A — no Prometheus metrics in scope for this refactor.

## Non-Functional Requirements
- Language/runtime: Elixir 1.16+, Erlang/OTP 26+
- Local dev: `mix test` runs all tests; no new dependencies
- Observability: Existing `Logger` calls preserved in both modules
- Safety: Port cleanup on error/timeout must be preserved exactly; no resource leaks
- Documentation: `@moduledoc`, `@doc`, `@spec` on all public functions per project conventions
- Performance: No measurable overhead from the indirection layer — the facade pattern adds one function call

---

## Assumptions / System Model
- Deployment environment: Local development (same machine as orchestrator)
- Failure modes: Port crash (non-zero exit), port hang (timeout), port silent death (idle check), malformed NDJSON (parse error), missing result line
- Delivery guarantees: Synchronous — caller blocks until the spawned process completes or times out
- Multi-tenancy: N/A — single orchestrator process

---

## Data Model (as relevant to your role)

### SpawnBackend.Local Handle
The handle returned by `SpawnBackend.Local.spawn/1` encapsulates the port state:

- **port** — the Erlang port reference (required)
- **os_pid** — the OS process ID of the spawned process (optional, extracted after port open)
- **timer_ref** — the timeout timer reference (required)

This is an opaque struct internal to `SpawnBackend.Local`. Provider.CLI receives it from `spawn/1` and passes it to `stream/1` and `stop/1`.

### Provider.CLI Config
Provider.CLI accepts the same keyword options as `Spawner.spawn/1` today. No new config fields are needed for this implementation — the `provider: cli` and `backend: local` config mapping is handled by the Config Engineer.

### Validation Rules
- `:team_name` and `:prompt` are required (enforced by `Keyword.fetch!`)
- `:command` defaults to `"claude"`, resolved via `System.find_executable/1`
- `:timeout_minutes` must be positive (existing implicit constraint)

### Versioning Strategy
N/A — no persisted data model changes.

---

## APIs (as relevant to your role)

### SpawnBackend.Local (implements SpawnBackend behaviour)

```elixir
@spec spawn(keyword()) :: {:ok, handle()} | {:error, term()}
# Opens an Erlang port to the resolved command with args.
# Returns an opaque handle containing the port, os_pid, and timer_ref.
# Options: :command, :args, :cwd, :timeout_ms, :env

@spec stream(handle()) :: Enumerable.t()
# Returns a stream of raw binary chunks from the port's stdout.
# Each chunk is a `{port, {:data, binary}}` message.
# Terminates on `{port, {:exit_status, code}}` or timeout.

@spec stop(handle()) :: :ok
# Closes the port, cancels the timer, kills the OS process if needed.

@spec status(handle()) :: :running | :done | :failed
# Checks if the port process is still alive via Port.info + kill -0.
```

**Error semantics:**
- `spawn/1` returns `{:error, :command_not_found}` if the command cannot be resolved
- `stream/1` yields `{:exit, code}` tuples on non-zero exit
- `stop/1` is idempotent — safe to call multiple times

### Provider.CLI (implements Provider behaviour)

```elixir
@spec start(keyword()) :: {:ok, provider_state()} | {:error, term()}
# Initializes provider state from config options.
# Validates required fields, resolves command path.

@spec run(provider_state(), String.t(), keyword()) :: {:ok, TeamResult.t()} | {:error, term()}
# Executes a prompt against the CLI backend.
# 1. Builds CLI args (or resume args if :session_id is present)
# 2. Delegates to SpawnBackend.Local.spawn/1
# 3. Collects output via the collect loop (ported from Spawner)
# 4. Parses NDJSON, accumulates tokens, extracts activities
# 5. Builds and returns TeamResult
# Options: :model, :max_turns, :permission_mode, :timeout_minutes,
#          :log_path, :session_id, :on_token_update, :on_activity, :on_port_opened

@spec stop(provider_state()) :: :ok
# Cleans up provider state. For CLI, this is a no-op (stateless).
```

**Error semantics:**
- `run/3` returns `{:error, {:exit_code, code, output}}` on non-zero exit (same as current Spawner)
- `run/3` returns `{:error, :no_result_line}` if process exits without a result NDJSON line
- `run/3` returns `{:ok, %TeamResult{status: :timeout}}` on timeout (same as current Spawner)

### Spawner Facade (preserved API)

```elixir
@spec spawn(keyword()) :: {:ok, TeamResult.t()} | {:error, term()}
# Delegates to Provider.CLI.run/3 with a fresh provider state.

@spec resume(keyword()) :: {:ok, TeamResult.t()} | {:error, term()}
# Delegates to Provider.CLI.run/3 with :session_id in options.

@spec extract_session_id_from_log(String.t()) :: {:ok, String.t()} | :error
# Unchanged — stays in Spawner (file I/O, not provider-specific).
```

---

## Architecture / Component Boundaries (as relevant)

### Components I Touch

- **`Cortex.SpawnBackend.Local`** (`lib/cortex/spawn_backend/local.ex`)
  - Owns: Erlang port lifecycle (open, read, kill, cleanup), command resolution, env stripping, shell escaping, idle-check logic
  - Extracted from: `Spawner.open_port/3`, `Spawner.kill_port/1`, `Spawner.port_alive?/1`, `Spawner.resolve_command/1`, `Spawner.shell_escape/1`

- **`Cortex.Provider.CLI`** (`lib/cortex/provider/cli.ex`)
  - Owns: NDJSON stream parsing, token accumulation, activity extraction, tool detail formatting, log device management, TeamResult construction, callback notifications
  - Extracted from: `Spawner.collect_output/6`, `Spawner.collect_loop/4`, `Spawner.parse_ndjson_line/3`, `Spawner.extract_lines/1`, `Spawner.build_team_result/3`, `Spawner.build_args/4`, `Spawner.build_resume_args/2`, and all `extract_*`/`safe_notify_*`/`tool_detail*` helpers

- **`Cortex.Orchestration.Spawner`** (`lib/cortex/orchestration/spawner.ex`)
  - Becomes: Thin facade — `spawn/1` and `resume/1` delegate to `Provider.CLI`; `extract_session_id_from_log/1` stays in place
  - Why facade: 7 call sites across `executor.ex`, `reconciler.ex`, `mesh/session_runner.ex`, `gossip/session_runner.ex`, `launcher.ex`, `run_detail_live.ex`, `team_detail_live.ex`. Keeping Spawner as a facade means zero changes to callers in this phase. The Integration Engineer can update callers to use Provider directly in a separate task.

### Components I Do NOT Touch
- `Cortex.Provider` behaviour module (Behaviour Architect)
- `Cortex.SpawnBackend` behaviour module (Behaviour Architect)
- Config schema / loader / validator (Config Engineer)
- `Runner.Executor`, `Reconciler`, `SessionRunner` call sites (Integration Engineer)

### How Config Changes Propagate
N/A for this role — Provider.CLI reads its config from the keyword options passed in at call time. The Config Engineer handles adding `provider`/`backend` fields to the YAML schema, and the Integration Engineer handles resolving those fields to the correct Provider/SpawnBackend modules.

### Concurrency Model
No change from current model. `Provider.CLI.run/3` is synchronous and blocking (same as `Spawner.spawn/1`). Concurrency is handled by the callers (`Task.async` in `Executor.run_team/6`).

### Backpressure Strategy
N/A — synchronous port I/O, no queuing.

---

## Correctness Invariants (must be explicit)

1. **API compatibility:** `Spawner.spawn/1` and `Spawner.resume/1` return identical results (type, shape, values) before and after the refactor. No caller observes any difference.
2. **Port cleanup:** Every opened port is closed on all exit paths — success, error, timeout, and unexpected crashes. The `try/after` pattern in Spawner is preserved in Provider.CLI.
3. **Log file lifecycle:** Log devices are opened before port spawn and closed in `after` blocks, even on errors. Parent directories are created. Same as current behavior.
4. **NDJSON parsing fidelity:** All NDJSON line types (`system/init`, `result`, `assistant`, `message_start`, `message_delta`, `content_block_start`) are parsed identically. Non-JSON lines are skipped.
5. **Token accumulation accuracy:** Running totals for `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens` match the current accumulation logic exactly.
6. **Timeout behavior:** Timeout fires after `timeout_minutes * 60 * 1000` ms, kills the port, cancels the timer, returns `%TeamResult{status: :timeout}`.
7. **Idle check behavior:** After `@idle_check_ms` (2 min) of no output, checks if port is alive. If dead, returns `{:error, {:port_died, output}}`.
8. **Callback safety:** `on_token_update`, `on_activity`, and `on_port_opened` callbacks are wrapped in `rescue` blocks — exceptions never crash the collect loop.
9. **Environment stripping:** `CLAUDECODE` and `CLAUDE_CODE_ENTRYPOINT` env vars are stripped from the child process environment.
10. **All 13 existing SpawnerTest cases pass unchanged.**

---

## Tests

### Unit Tests — `test/cortex/spawn_backend/local_test.exs`
- Port opens successfully with a valid command and returns a handle
- Port returns exit status 0 on normal completion
- Port returns non-zero exit status on failure
- `stop/1` closes the port and is idempotent
- `status/1` returns `:running` for an active port
- `status/1` returns `:done` or `:failed` for a completed port
- Timeout timer fires and port is killed
- Environment variables `CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT` are stripped
- Command resolution falls back to raw path when `System.find_executable` returns nil

### Unit Tests — `test/cortex/provider/cli_test.exs`
- NDJSON parsing: `system/init` line extracts session_id
- NDJSON parsing: `result` line with `subtype: "success"` produces `:success` status
- NDJSON parsing: `result` line with `subtype: "error"` produces `:error` status
- NDJSON parsing: `result` with rate_limit text produces `:rate_limited` status
- NDJSON parsing: non-JSON lines are skipped without error
- Token accumulation across multiple usage messages
- Activity extraction from `assistant` messages with `tool_use` blocks
- Activity extraction from `content_block_start` messages
- Tool detail formatting for each known tool type (Bash, Read, Write, Edit, Grep, Glob, Agent, WebSearch, WebFetch)
- `on_token_update` callback receives accumulated tokens
- `on_activity` callback receives parsed activities
- `on_port_opened` callback receives OS pid
- Log device is opened, written to, and closed
- Full integration: mock script -> Provider.CLI.run -> TeamResult (mirrors existing SpawnerTest cases)

### Integration Tests — existing `test/cortex/orchestration/spawner_test.exs`
- All 13 existing test cases pass unchanged (the facade delegates to Provider.CLI)

### Failure Injection Tests
- Command not found → `{:error, term()}`
- Port crashes mid-stream → `{:error, {:exit_code, code, output}}`
- Callback raises exception → collect loop continues without crash
- Log path on read-only filesystem → warning logged, nil device, spawn proceeds

### Commands
```bash
mix test test/cortex/spawn_backend/local_test.exs
mix test test/cortex/provider/cli_test.exs
mix test test/cortex/orchestration/spawner_test.exs
mix test  # all tests pass
mix compile --warnings-as-errors
mix credo --strict
mix format --check-formatted
```

---

## Benchmarks + "Success"

N/A — this is a pure refactor with no new capabilities and no performance-sensitive changes. The indirection layer adds one function call (~microseconds). The existing `bench/agent_bench.exs` benchmarks exercise the Spawner path and will confirm no regression.

**Success criteria:**
- All existing tests pass (`mix test` green)
- Zero compiler warnings (`mix compile --warnings-as-errors`)
- Clean credo (`mix credo --strict`)
- The facade is transparent: `Spawner.spawn/1` produces byte-identical `TeamResult` structs before and after

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### Decision 1: Facade Pattern for Spawner
- **Decision:** Keep `Spawner` as a thin facade that delegates to `Provider.CLI`, rather than updating all 7 call sites in one go.
- **Alternatives considered:** (a) Delete Spawner entirely and update all callers to use Provider.CLI directly. (b) Keep Spawner as a full copy and deprecate it.
- **Why:** The facade pattern means zero changes to callers (`executor.ex`, `reconciler.ex`, `mesh/session_runner.ex`, `gossip/session_runner.ex`, `launcher.ex`, `run_detail_live.ex`, `team_detail_live.ex`). This isolates the refactor to 3 files (new CLI, new Local, modified Spawner) and makes it safe to land independently. The Integration Engineer can later update callers to use Provider directly, with the facade as a safety net during the transition.
- **Tradeoff acknowledged:** An extra layer of indirection that could become stale. Mitigated by the Integration Engineer's task to update callers, after which the facade body shrinks to just `extract_session_id_from_log/1`.

### Decision 2: Port Lifecycle Ownership in SpawnBackend.Local vs Provider.CLI
- **Decision:** `SpawnBackend.Local` owns port opening, the receive loop for `{port, {:data, _}}` and `{port, {:exit_status, _}}` messages, and port cleanup. `Provider.CLI` owns the parsing/interpretation of the data received.
- **Alternatives considered:** (a) Keep the full collect loop in Provider.CLI and only extract `Port.open` into SpawnBackend.Local. (b) Have SpawnBackend.Local return a raw stream and let Provider.CLI iterate it.
- **Why:** The receive loop is tightly coupled to port semantics (message format, exit_status, idle checks). Keeping it in SpawnBackend.Local means future backends (Docker, K8s) can provide their own `stream/1` implementations with different transport semantics (HTTP SSE, gRPC streaming) while Provider.CLI's parsing logic stays unchanged. However, the NDJSON parsing and callback invocation must happen inline during the receive loop (not after), because `on_token_update` and `on_activity` deliver real-time progress. So Provider.CLI provides a callback/handler that SpawnBackend.Local invokes on each data chunk.
- **Tradeoff acknowledged:** The boundary between "transport" and "parsing" is not perfectly clean — the collect loop interleaves port reads with NDJSON parsing. We accept this coupling because splitting them would require buffering all output (breaking real-time callbacks) or complex stream abstractions that add no value for the CLI case. The key architectural win is that `SpawnBackend.Local` can be swapped for `SpawnBackend.Docker` without touching Provider.CLI's parsing logic.

### Decision 3: Callback-Based Data Flow (not Stream-Based)
- **Decision:** Provider.CLI passes a `on_data` callback to SpawnBackend.Local's collect/stream function, which is invoked on each data chunk. This preserves the current synchronous, blocking, callback-driven architecture.
- **Alternatives considered:** (a) GenStage/Flow-based stream processing. (b) Return an `Enumerable` from SpawnBackend.Local and have Provider.CLI consume it.
- **Why:** The current architecture is synchronous and works well. The callers (`Task.async` in Executor) already handle concurrency. Introducing GenStage or lazy streams would add complexity with no benefit — the port produces data at the rate the child process outputs it, and there's no backpressure scenario. The callback pattern maps directly to the existing `collect_loop` structure.
- **Tradeoff acknowledged:** Less composable than a stream-based approach. If a future use case needs to tee output to multiple consumers, the callback approach requires explicit fan-out. Acceptable for now since no such use case exists.

---

## Risks & Mitigations (REQUIRED)

### Risk 1: Behaviour API Mismatch
- **Risk:** The Behaviour Architect defines `Provider` and `SpawnBackend` callbacks with signatures that don't match the implementation I've planned (e.g., different arity, different return types, GenServer-based instead of functional).
- **Impact:** Rework of Provider.CLI and SpawnBackend.Local to match the behaviour contracts. Could delay implementation.
- **Mitigation:** Read the Behaviour Architect's plan before starting implementation. If the behaviour is not yet defined, implement Provider.CLI and SpawnBackend.Local with the API described in this plan, then adapt to the behaviour once it lands. The adaptation should be mechanical (adding `@behaviour` and adjusting function signatures).
- **Validation time:** 5 minutes — read the behaviour module definitions once they exist.

### Risk 2: Collect Loop Extraction Breaks Timing
- **Risk:** Moving the collect loop into a different module changes message ordering or timing in subtle ways (e.g., if the receive loop is no longer in the same process as the port owner).
- **Impact:** Flaky tests, especially the timeout test (`spawn/1 with timeout`) which relies on precise timing.
- **Mitigation:** The port owner process and the receive loop MUST remain in the same process. Provider.CLI.run/3 is called synchronously in the caller's process, and it opens the port in that same process. The refactor moves code between modules but NOT between processes. Verify by running the timeout test 20 times: `mix test test/cortex/orchestration/spawner_test.exs --seed 0 --repeat-until-failure 20`.
- **Validation time:** 2 minutes.

### Risk 3: Subtle Behaviour Difference in Facade Delegation
- **Risk:** The facade introduces a subtle difference — e.g., keyword option handling, default values applied in a different order, or a missing option passthrough — that causes a test to fail or a caller to misbehave.
- **Impact:** Broken tests or silent behaviour change in production.
- **Mitigation:** The facade's `spawn/1` and `resume/1` must pass through ALL keyword options to Provider.CLI without filtering or transforming. Write a specific test that verifies the facade produces byte-identical output to the old Spawner for the same inputs. Run the full test suite after every change.
- **Validation time:** 3 minutes — run `mix test` and check for regressions.

### Risk 4: NDJSON Parsing Logic Duplication or Divergence
- **Risk:** During extraction, a parsing helper is accidentally copied instead of moved, leading to two copies that could diverge over time.
- **Impact:** Bugs where Spawner and Provider.CLI parse NDJSON differently.
- **Mitigation:** The extraction is a clean move: all NDJSON parsing functions are removed from Spawner and placed in Provider.CLI. Spawner retains only `extract_session_id_from_log/1` (which reads files, not streams). `mix compile --warnings-as-errors` will catch any dangling references. Credo will flag duplicated code.
- **Validation time:** 1 minute — `mix compile --warnings-as-errors`.

---

## Recommended API Surface

### `Cortex.SpawnBackend.Local`

| Function | Behaviour | Description |
|----------|-----------|-------------|
| `spawn(opts)` | `SpawnBackend.spawn/1` | Open Erlang port, return handle |
| `stream(handle, on_data)` | `SpawnBackend.stream/1` | Receive loop; invokes callback per chunk; returns on exit/timeout |
| `stop(handle)` | `SpawnBackend.stop/1` | Kill port, cancel timer |
| `status(handle)` | `SpawnBackend.status/1` | Check if port process is alive |

### `Cortex.Provider.CLI`

| Function | Behaviour | Description |
|----------|-----------|-------------|
| `start(opts)` | `Provider.start/1` | Validate options, return provider state |
| `run(state, prompt, opts)` | `Provider.run/3` | Full spawn-parse-result pipeline |
| `stop(state)` | `Provider.stop/1` | No-op for CLI (stateless) |

### `Cortex.Orchestration.Spawner` (facade)

| Function | Delegates To | Change |
|----------|-------------|--------|
| `spawn(opts)` | `Provider.CLI.run/3` | Body replaced with delegation |
| `resume(opts)` | `Provider.CLI.run/3` | Body replaced with delegation |
| `extract_session_id_from_log(path)` | (self) | Unchanged |

---

## Folder Structure

```
lib/cortex/
  provider/
    cli.ex                    # NEW — Provider.CLI implementation
  spawn_backend/
    local.ex                  # NEW — SpawnBackend.Local implementation
  orchestration/
    spawner.ex                # MODIFIED — becomes thin facade

test/cortex/
  provider/
    cli_test.exs              # NEW — Provider.CLI unit tests
  spawn_backend/
    local_test.exs            # NEW — SpawnBackend.Local unit tests
  orchestration/
    spawner_test.exs          # UNCHANGED — existing tests validate facade
```

---

## Tighten the plan into 4–7 small tasks (STRICT)

### Task 1: Implement SpawnBackend.Local
- **Outcome:** A working `SpawnBackend.Local` module that handles Erlang port lifecycle — open, read, stop, status, timeout, idle-check, env stripping, command resolution.
- **Files to create/modify:**
  - Create `lib/cortex/spawn_backend/local.ex`
  - Create `test/cortex/spawn_backend/local_test.exs`
- **Exact verification command(s):**
  ```bash
  mix test test/cortex/spawn_backend/local_test.exs
  mix compile --warnings-as-errors
  mix credo --strict lib/cortex/spawn_backend/local.ex
  ```
- **Suggested commit message:** `feat(spawn_backend): implement SpawnBackend.Local with Erlang port lifecycle`

### Task 2: Implement Provider.CLI
- **Outcome:** A working `Provider.CLI` module that owns NDJSON parsing, token accumulation, activity extraction, log file management, callback notifications, and TeamResult construction. Delegates port management to SpawnBackend.Local.
- **Files to create/modify:**
  - Create `lib/cortex/provider/cli.ex`
  - Create `test/cortex/provider/cli_test.exs`
- **Exact verification command(s):**
  ```bash
  mix test test/cortex/provider/cli_test.exs
  mix compile --warnings-as-errors
  mix credo --strict lib/cortex/provider/cli.ex
  ```
- **Suggested commit message:** `feat(provider): implement Provider.CLI with NDJSON parsing and TeamResult construction`

### Task 3: Convert Spawner to Facade
- **Outcome:** `Spawner.spawn/1` and `Spawner.resume/1` delegate to `Provider.CLI.run/3`. All private parsing/port functions are removed from Spawner. `extract_session_id_from_log/1` stays. All existing SpawnerTest cases pass unchanged.
- **Files to create/modify:**
  - Modify `lib/cortex/orchestration/spawner.ex` — replace body of `spawn/1` and `resume/1`, remove all private helpers that moved to Provider.CLI and SpawnBackend.Local
- **Exact verification command(s):**
  ```bash
  mix test test/cortex/orchestration/spawner_test.exs
  mix test
  mix compile --warnings-as-errors
  mix credo --strict lib/cortex/orchestration/spawner.ex
  ```
- **Suggested commit message:** `refactor(spawner): convert to thin facade delegating to Provider.CLI`

### Task 4: Verify Full Test Suite + Linting
- **Outcome:** All tests pass, no warnings, clean credo, clean format. The refactor is invisible to all callers.
- **Files to create/modify:** None (verification only; fix any issues found)
- **Exact verification command(s):**
  ```bash
  mix format
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix credo --strict
  mix test
  ```
- **Suggested commit message:** `chore: verify CLI refactor — all tests pass, clean lint`

### Task 5: Add @behaviour Annotations (after Behaviour Architect lands)
- **Outcome:** `Provider.CLI` declares `@behaviour Cortex.Provider` and `SpawnBackend.Local` declares `@behaviour Cortex.SpawnBackend`. Function signatures are adapted if needed to match the behaviour callbacks.
- **Files to create/modify:**
  - Modify `lib/cortex/provider/cli.ex` — add `@behaviour` and adjust signatures if needed
  - Modify `lib/cortex/spawn_backend/local.ex` — add `@behaviour` and adjust signatures if needed
- **Exact verification command(s):**
  ```bash
  mix compile --warnings-as-errors  # catches missing behaviour callbacks
  mix test
  ```
- **Suggested commit message:** `feat(provider): wire Provider.CLI and SpawnBackend.Local to behaviour contracts`

---

## CLAUDE.md contributions (do NOT write the file; propose content)

## From CLI Refactor Engineer

### Architecture
- `Provider.CLI` (`lib/cortex/provider/cli.ex`) — wraps CLI spawning behind the Provider behaviour. Owns NDJSON parsing, token accumulation, and TeamResult construction.
- `SpawnBackend.Local` (`lib/cortex/spawn_backend/local.ex`) — Erlang port lifecycle management. Extracted from Spawner.
- `Spawner` (`lib/cortex/orchestration/spawner.ex`) — thin facade; delegates to Provider.CLI. Preserved for backward compatibility with existing callers.

### Coding Style
- Provider implementations must return `{:ok, TeamResult.t()} | {:error, term()}` from `run/3`
- SpawnBackend implementations must return opaque handles from `spawn/1`; callers must not inspect handle internals
- Callback options (`on_token_update`, `on_activity`, `on_port_opened`) must be wrapped in `rescue` blocks

### Dev Commands
```bash
mix test test/cortex/provider/cli_test.exs       # Provider.CLI tests
mix test test/cortex/spawn_backend/local_test.exs # SpawnBackend.Local tests
mix test test/cortex/orchestration/spawner_test.exs # Facade regression tests
```

### Before You Commit
- All 3 test files above must pass
- `mix compile --warnings-as-errors` — catches missing behaviour callbacks
- Spawner facade must not contain any NDJSON parsing logic (it belongs in Provider.CLI)

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture
- The spawning pipeline now has three layers: Spawner (facade) -> Provider.CLI (parsing + result) -> SpawnBackend.Local (port I/O)
- `Provider.CLI.run/3` is the new entrypoint for CLI-based agent spawning; it opens a port via SpawnBackend.Local, parses the NDJSON output stream, accumulates token usage, and returns a `TeamResult`
- The Spawner module is preserved as a backward-compatible facade that delegates to Provider.CLI, allowing all 7 existing call sites to work without modification

### Key Engineering Decisions + Tradeoffs
- **Facade pattern** chosen over direct caller updates to minimize blast radius and enable incremental migration
- **Callback-based data flow** (not streams) to preserve the synchronous, blocking architecture that callers depend on
- **Port lifecycle in SpawnBackend.Local** because future backends (Docker, K8s) need different transport mechanics but Provider.CLI's parsing logic stays the same

### Limits of MVP + Next Steps
- Provider.CLI is functionally identical to the old Spawner — no new capabilities
- The facade adds one layer of indirection; the Integration Engineer will later update callers to use Provider directly
- The `@behaviour` annotations depend on the Behaviour Architect's module landing first

### How to Run Locally + Validate
- `mix test` — all tests pass (no changes to test expectations)
- `mix test test/cortex/orchestration/spawner_test.exs` — verifies the facade is transparent
- `mix compile --warnings-as-errors` — catches any dangling references to moved functions

---

## READY FOR APPROVAL
