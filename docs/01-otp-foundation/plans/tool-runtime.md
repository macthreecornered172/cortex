# Tool Runtime Plan

## You are in PLAN MODE.

### Project
I want to build a **multi-agent orchestration system on Elixir/OTP (Cortex)**.

**Goal:** build a **tool execution runtime** in which agents can invoke tools in sandboxed, isolated processes with timeout enforcement, crash isolation, and a behaviour-based extensibility contract.

### Role + Scope
- **Role:** Tool Runtime Lead
- **Scope:** Tool behaviour definition, executor (sandboxed Task-based execution with timeout), Task.Supervisor for tool processes, tool registry (Agent-backed name-to-module lookup), and one built-in tool (shell command execution with allowlist). I do NOT own the Agent GenServer, supervision tree wiring in Application, LLM client, config parsing, event system, or PubSub.
- **File you will write:** `/docs/01-otp-foundation/plans/tool-runtime.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

1. **Tool Behaviour Contract** -- Any module implementing `Cortex.Tool.Behaviour` is a valid tool. The contract exposes four callbacks:
   - `name/0` -- a unique string identifier for lookup.
   - `description/0` -- human-readable description for agent prompt injection.
   - `schema/0` -- JSON Schema map describing expected arguments.
   - `execute/1` -- takes an args map, returns `{:ok, result}` or `{:error, reason}`.

2. **Sandboxed Execution** -- `Cortex.Tool.Executor.run/3` spawns a Task under `Cortex.Tool.Supervisor` (a `Task.Supervisor`). The tool's `execute/1` runs inside that task. The calling process (an agent GenServer) is never at risk of crashing due to a tool failure.

3. **Timeout Enforcement** -- Each execution has a configurable timeout (default 30 seconds). If the tool does not return within the timeout, the task is killed and `{:error, :timeout}` is returned. No zombie processes are left behind.

4. **Crash Isolation** -- If a tool raises an exception or exits abnormally, the executor catches it and returns `{:error, {:exception, reason}}`. The calling process receives a clean error tuple, never a crash signal.

5. **Tool Registry** -- An Agent process (`Cortex.Tool.Registry`) maintains a map of `tool_name => module`. Supports `register/1`, `lookup/1`, and `list/0`. Tools are registered by passing the module; the registry calls `module.name()` to derive the key.

6. **Built-in Shell Tool** -- `Cortex.Tool.Builtin.Shell` implements the behaviour. It runs a shell command via `System.cmd/3` with:
   - A configurable allowlist of permitted commands (default: `["ls", "cat", "echo", "wc", "head", "tail", "grep", "find", "pwd", "date"]`).
   - Timeout enforcement on the OS process (via `System.cmd` `:timeout` option, distinct from Task timeout).
   - Max output size capping (default 64KB) to prevent memory blowout.
   - Returns stdout as the result string, stderr in the error tuple if exit code != 0.

## Non-Functional Requirements

1. **Isolation guarantee** -- A crashing tool must never crash the calling agent or any other agent. This is the single most important invariant. Verified by fault injection tests.
2. **No process leaks** -- After a timeout or crash, no orphan processes remain linked to the supervisor or registry. Task.Supervisor handles this natively, but we must verify it.
3. **Concurrency** -- Multiple tools can execute simultaneously under the same Task.Supervisor. There is no global lock on tool execution.
4. **Extensibility** -- Adding a new tool requires only implementing the behaviour and calling `Registry.register/1`. No changes to executor or supervisor.
5. **Deterministic testing** -- All tool runtime tests must be async-safe (no shared mutable state except the registry, which gets a unique name per test where needed).

## Assumptions / System Model

- The `Cortex.Tool.Supervisor` is started by `Cortex.Application` as part of the supervision tree (owned by Scaffold Lead). Tool Runtime Lead defines the child spec but does not wire it into Application.
- Tools are synchronous from the caller's perspective: `Executor.run/3` blocks until result, timeout, or error. Async/streaming tool execution is out of scope for Phase 1.
- The tool registry is in-memory only. There is no persistence of registered tools. On application restart, tools must be re-registered (typically in Application.start or by the config loader in Phase 3).
- `System.cmd/3` is the execution mechanism for the Shell tool. We do NOT use `Port.open` or `:os.cmd` -- `System.cmd` gives us proper argument separation (no shell injection via argument list), timeout support, and clean exit code handling.
- Tool argument validation against the JSON schema is a Phase 3 concern (when agents dynamically select and invoke tools). For Phase 1, `execute/1` receives a pre-validated map.

## Data Model

### Tool Behaviour (protocol/contract, not a struct)
```
@callback name() :: String.t()
@callback description() :: String.t()
@callback schema() :: map()
@callback execute(args :: map()) :: {:ok, term()} | {:error, term()}
```

### Tool Registry State (internal to Agent process)
```
%{
  String.t() => module()
}
# Example: %{"shell" => Cortex.Tool.Builtin.Shell}
```

### Executor Result Type
```
{:ok, term()} | {:error, :timeout} | {:error, {:exception, term()}} | {:error, term()}
```

### Shell Tool Args Schema
```json
{
  "type": "object",
  "properties": {
    "command": {"type": "string", "description": "The command to execute"},
    "args": {"type": "array", "items": {"type": "string"}, "description": "Command arguments"},
    "timeout_ms": {"type": "integer", "description": "Timeout in milliseconds", "default": 10000}
  },
  "required": ["command"]
}
```

## APIs

### `Cortex.Tool.Executor`

```
@spec run(module(), map(), keyword()) :: {:ok, term()} | {:error, term()}
```

- `tool_module` -- a module implementing `Cortex.Tool.Behaviour`.
- `args` -- a map of arguments passed to `tool_module.execute/1`.
- `opts` -- keyword list. Supported keys:
  - `:timeout` -- integer milliseconds (default `30_000`).
  - `:supervisor` -- Task.Supervisor name (default `Cortex.Tool.Supervisor`). Useful for testing with isolated supervisors.

Behavior:
1. Spawn a `Task.Supervisor.async_nolink/3` task.
2. `Task.yield(task, timeout)` to wait.
3. On `{:ok, result}` from yield -- return the tool's result directly.
4. On `nil` (timeout) -- `Task.shutdown(task, :brutal_kill)`, return `{:error, :timeout}`.
5. On `{:exit, reason}` -- return `{:error, {:exception, reason}}`.

### `Cortex.Tool.Registry`

```
@spec start_link(keyword()) :: {:ok, pid()}
@spec register(module()) :: :ok | {:error, :invalid_tool}
@spec lookup(String.t()) :: {:ok, module()} | {:error, :not_found}
@spec list() :: [module()]
```

- `start_link/1` -- starts the Agent process. Accepts `:name` option (default `Cortex.Tool.Registry`).
- `register/1` -- validates that the module implements the behaviour (has `name/0`), then stores `module.name() => module`.
- `lookup/1` -- returns `{:ok, module}` or `{:error, :not_found}`.
- `list/0` -- returns all registered modules.

### `Cortex.Tool.Supervisor`

```
# Child spec for Application supervisor:
{Task.Supervisor, name: Cortex.Tool.Supervisor}
```

Thin module that wraps `Task.Supervisor` child spec. No custom logic -- the supervisor is vanilla `Task.Supervisor`. The module exists so the child spec is in one place and tests can reference it.

### `Cortex.Tool.Builtin.Shell`

```
@spec execute(map()) :: {:ok, String.t()} | {:error, term()}
```

Args: `%{"command" => "ls", "args" => ["-la"], "timeout_ms" => 5000}`

Behavior:
1. Validate `command` is in the allowlist. If not, return `{:error, {:disallowed_command, command}}`.
2. Call `System.cmd(command, args, stderr_to_stdout: true, timeout: timeout_ms)`.
   Note: `System.cmd` does not natively support `:timeout` -- we must use `Task` + `System.cmd` for timeout, or use `Port` with manual timeout. **Decision: wrap `System.cmd` in a spawned process with a timeout via the enclosing Task from the executor.** The shell tool itself does not enforce its own timeout; it relies on the executor's timeout. The `timeout_ms` arg is advisory and sets a lower ceiling on the executor timeout.
3. If exit code is 0, return `{:ok, stdout}` (truncated to max output size).
4. If exit code != 0, return `{:error, {:exit_code, code, stdout}}`.

## Architecture / Component Boundaries

```
lib/cortex/tool/
  behaviour.ex      -- @callback definitions (no runtime code)
  executor.ex        -- run/3 function, Task spawning, timeout/crash handling
  supervisor.ex      -- Task.Supervisor child spec wrapper
  registry.ex        -- Agent-backed tool name => module map
  builtin/
    shell.ex         -- Shell command tool implementation
```

**Boundary with Agent Core:** Agents call `Cortex.Tool.Executor.run/3` when they need to execute a tool. The agent decides which tool to invoke (based on LLM output, Phase 3). The tool runtime has zero knowledge of agents.

**Boundary with Scaffold:** The Scaffold Lead wires `Cortex.Tool.Supervisor` and `Cortex.Tool.Registry` into `Cortex.Application`'s supervision tree. Tool Runtime Lead provides the child specs.

**Boundary with Events:** Tool execution does NOT broadcast events in Phase 1. Event emission for tool start/complete is a Phase 2 (QE) or Phase 3 concern. The executor is pure: input -> output.

## Correctness Invariants

1. **Crash isolation is absolute.** If `tool_module.execute/1` raises, exits, or throws, `Executor.run/3` always returns a tagged error tuple. The calling process is never killed or affected. Verified by: running a tool that calls `Process.exit(self(), :kill)` and confirming the caller survives.

2. **Timeout kills the task.** After `Executor.run/3` returns `{:error, :timeout}`, the spawned Task process is dead (not sleeping in the background). Verified by: checking `Process.alive?` on the task pid after timeout.

3. **No duplicate tool names.** `Registry.register/1` called twice with different modules that share the same `name()` overwrites the first. This is intentional -- last-write-wins enables tool hot-swapping. If we need error semantics instead, we return `{:error, :already_registered}`. **Decision: last-write-wins** for simplicity and hot-reload friendliness.

4. **Shell allowlist is enforced before execution.** A disallowed command never reaches `System.cmd`. The allowlist is checked first, and the function returns immediately on violation.

5. **Registry validates behaviour compliance.** `register/1` checks that the module exports `name/0`, `description/0`, `schema/0`, and `execute/1` (via `function_exported?/3`). Invalid modules are rejected with `{:error, :invalid_tool}`.

## Tests

### Unit Tests

- **`test/cortex/tool/behaviour_test.exs`** -- Verify that a module implementing the behaviour compiles and all callbacks are callable. Test with a minimal `TestTool` module defined in the test file.

- **`test/cortex/tool/executor_test.exs`** -- Core executor tests:
  - Successful tool returns `{:ok, result}`.
  - Tool raising an exception returns `{:error, {:exception, _}}`.
  - Tool exceeding timeout returns `{:error, :timeout}`.
  - Tool calling `Process.exit(self(), :kill)` returns an error, caller survives.
  - Timed-out task process is dead after return.
  - Concurrent executions (5 parallel) all return independently.
  - Tool runs in a different process than caller (`self()` comparison).

- **`test/cortex/tool/registry_test.exs`** -- Registry tests:
  - `register/1` + `lookup/1` roundtrip.
  - `lookup/1` for unregistered name returns `{:error, :not_found}`.
  - `list/0` returns all registered modules.
  - Registering a non-behaviour module returns `{:error, :invalid_tool}`.
  - Re-registering with same name overwrites (last-write-wins).

- **`test/cortex/tool/builtin/shell_test.exs`** -- Shell tool tests:
  - Allowed command executes and returns stdout.
  - Disallowed command returns `{:error, {:disallowed_command, _}}`.
  - Command with non-zero exit code returns error with exit code and output.
  - Output truncation at max size.
  - Empty args list works.

### Integration Tests

- **`test/cortex/tool/integration_test.exs`** -- End-to-end flow:
  - Start Tool.Supervisor and Registry, register Shell tool, execute via Executor, verify result.
  - Register multiple tools, look up by name, execute each.
  - Execute a crashing tool followed by a healthy tool -- second tool succeeds (supervisor not corrupted).

### Property/Fuzz Tests

- **Optional: `test/cortex/tool/executor_property_test.exs`** -- StreamData-based property test:
  - For any randomly generated args map, `Executor.run(EchoTool, args)` always returns `{:ok, args}`.
  - For any timeout value in 1..100ms with a SlowTool (sleeps 200ms), always returns `{:error, :timeout}`.

### Test Support Modules

- **`test/support/test_tools.ex`** -- Shared test tool implementations:
  - `Cortex.TestTools.Echo` -- returns args as-is.
  - `Cortex.TestTools.Slow` -- sleeps for `args["sleep_ms"]` then returns `:done`.
  - `Cortex.TestTools.Crasher` -- raises `RuntimeError`.
  - `Cortex.TestTools.Killer` -- calls `Process.exit(self(), :kill)`.
  - `Cortex.TestTools.BadReturn` -- returns `:not_a_tuple` (invalid return format).

### Commands

```bash
# Run all tool runtime tests
mix test test/cortex/tool/

# Run only executor tests
mix test test/cortex/tool/executor_test.exs

# Run with verbose output
mix test test/cortex/tool/ --trace

# Run the full suite
mix test
```

## Benchmarks + "Success"

### Benchmark Plan

Use `Benchee` to measure:

1. **Executor overhead** -- Compare direct `tool.execute(args)` call vs `Executor.run(tool, args)`. The overhead is the cost of Task spawning + supervision. Target: < 1ms overhead for a trivial (no-op) tool.

2. **Concurrent throughput** -- Spawn 100 concurrent `Executor.run` calls with the Echo tool. Measure wall-clock time and per-call latency. Target: all 100 complete within 500ms on a 4-core machine.

3. **Timeout accuracy** -- Set a 100ms timeout, run a tool that sleeps 200ms. Measure actual return time. Target: returns within 100-120ms (< 20% overshoot).

4. **Registry lookup speed** -- Register 100 tools, benchmark `lookup/1` by name. Target: < 10 microseconds per lookup (Agent `get` is fast).

### Success Criteria

| Metric | Target |
|--------|--------|
| Executor overhead (no-op tool) | < 1ms |
| Concurrent 100 executions | < 500ms wall clock |
| Timeout accuracy (100ms set) | Returns in 100-120ms |
| Registry lookup (100 tools) | < 10 microseconds |
| Crash isolation | 100% -- caller never crashes |
| Zero process leaks after timeout | 0 orphan processes |
| All unit tests pass | `mix test test/cortex/tool/` green |

## Engineering Decisions & Tradeoffs (REQUIRED)

### Decision 1: Agent process for Tool Registry vs ETS table

- **Decision:** Use an `Agent` process to back the tool registry.
- **Alternatives considered:** (a) ETS table owned by a GenServer; (b) persistent_term for read-heavy workloads; (c) a Registry (Elixir's built-in) with tools self-registering.
- **Why:** The tool registry is written rarely (at startup) and read infrequently (when an agent selects a tool). An Agent is the simplest correct solution -- no concurrency bugs, trivial to test, and the performance overhead is negligible for this access pattern. ETS would be warranted if we had thousands of lookups per second, which we do not. `persistent_term` is inappropriate because it triggers a global GC on every write. Elixir's Registry is designed for process registration, not data lookup.
- **Tradeoff acknowledged:** Agent serializes all reads through a single process. If tool lookup becomes a bottleneck (very unlikely), we would migrate to ETS. For Phase 1 with < 20 tools and infrequent lookups, this is the right call.

### Decision 2: Task.Supervisor.async_nolink + yield vs Task.Supervisor.start_child

- **Decision:** Use `Task.Supervisor.async_nolink/3` + `Task.yield/2` + `Task.shutdown/2` for tool execution.
- **Alternatives considered:** (a) `Task.Supervisor.start_child/2` (fire-and-forget, poll for result); (b) `Task.async/1` (linked task -- crash propagation); (c) spawning a raw process with `Process.monitor`.
- **Why:** `async_nolink` gives us a Task struct with a ref we can yield on, without linking to the caller. This means a crashing task sends a `:DOWN` message instead of killing the caller. `yield` + `shutdown` gives us clean timeout handling with guaranteed task cleanup. `start_child` would require manual result passing via message or ETS. `Task.async` links the task -- a crash would propagate to the caller, violating our isolation invariant.
- **Tradeoff acknowledged:** `async_nolink` requires the caller to handle the `:DOWN` message or risk mailbox pollution if not using `yield`. Since we always call `yield` or `shutdown`, this is handled. We also lose automatic crash propagation, which is exactly what we want.

### Decision 3: Last-write-wins for duplicate tool names in Registry

- **Decision:** When `register/1` is called with a module whose `name()` matches an already-registered tool, the new module silently replaces the old one.
- **Alternatives considered:** (a) Return `{:error, :already_registered}`; (b) Raise an exception; (c) Keep both and return a list on lookup.
- **Why:** Last-write-wins enables hot-swapping tool implementations during development and testing. In production, tools are registered once at startup, so collisions are a configuration bug, not a runtime race. Erroring would make tests more verbose (needing to handle already-registered) and would prevent legitimate use cases like replacing a tool with a mock.
- **Tradeoff acknowledged:** Silent overwrites can mask configuration errors where two tools accidentally share a name. Mitigation: log a warning when overwriting.

### Decision 4: Shell tool uses System.cmd (argument list) instead of :os.cmd (string)

- **Decision:** Use `System.cmd/3` with command and args as separate values, NOT a single shell string.
- **Alternatives considered:** (a) `:os.cmd/1` with a single string (shell interpretation); (b) `Port.open/2` for streaming output.
- **Why:** `System.cmd/3` takes the command and arguments separately, which means arguments are passed directly to the OS exec call without shell interpretation. This eliminates shell injection attacks entirely -- there is no shell in the middle. `:os.cmd` passes a string to `/bin/sh -c`, which interprets metacharacters, pipes, redirects, etc. `Port.open` gives streaming but adds complexity we do not need in Phase 1.
- **Tradeoff acknowledged:** We lose the ability to use shell features (pipes, redirects, globbing) in commands. This is acceptable because the Shell tool is meant for simple, well-defined commands. Complex shell operations can be written as dedicated tools.

## Risks & Mitigations (REQUIRED)

### Risk 1: Task.Supervisor silently drops tasks under heavy load

- **Risk:** If the Task.Supervisor is overwhelmed (e.g., hundreds of concurrent tool executions), new tasks may fail to start or the supervisor may become a bottleneck.
- **Impact:** Tool executions silently fail or time out despite the tool being fast.
- **Mitigation:** Add a guard in `Executor.run/3` that checks the supervisor's child count via `Task.Supervisor.children/1`. If above a configurable max (default 50), return `{:error, :too_many_concurrent_tools}` immediately. Benchmark with 100 concurrent tasks in CI to verify the ceiling.
- **Validation time:** 10 minutes -- write a load test spawning 100+ concurrent echo tools.

### Risk 2: Shell tool allowlist is too restrictive or too permissive

- **Risk:** The default allowlist may block commands agents need, or allow commands that are destructive (e.g., `rm` if accidentally added).
- **Impact:** Agents cannot complete tasks (too restrictive) or agents damage the host system (too permissive).
- **Mitigation:** Make the allowlist configurable via application config (`config :cortex, Cortex.Tool.Builtin.Shell, allowed_commands: [...]`). Default to a conservative, read-only list. Log every shell command execution at `:info` level. In Phase 3, add a confirmation mechanism where destructive commands require explicit agent approval.
- **Validation time:** 5 minutes -- review the default list, try a few representative commands.

### Risk 3: System.cmd hangs indefinitely on a blocking command

- **Risk:** Some commands (e.g., `tail -f`, `cat /dev/urandom`) never terminate. `System.cmd/3` does not have a built-in timeout option in all Elixir versions.
- **Impact:** The Task running the shell tool hangs, consuming a scheduler thread. The executor's timeout kills the Task, but the underlying OS process may become orphaned.
- **Mitigation:** Use `Port.open/2` with `{:spawn_executable, cmd}` instead of `System.cmd` for the shell tool, combined with `Port.close/1` on timeout. Alternatively, wrap the command with `timeout` (coreutils) on the OS level: `System.cmd("timeout", [to_string(seconds), command | args])`. Decision: use the OS `timeout` wrapper as the simplest approach, falling back to executor-level Task timeout as the backstop.
- **Validation time:** 10 minutes -- run `Executor.run(Shell, %{"command" => "sleep", "args" => ["60"]})` with a 2s timeout, verify the sleep process is dead after return.

### Risk 4: Test tool modules conflict with production module loading

- **Risk:** Test support modules (Echo, Crasher, etc.) defined in `test/support/` may accidentally be included in production builds or conflict with real tools.
- **Impact:** Minimal -- test modules are not compiled in prod. But if someone adds `test/support` to `elixirc_paths` for prod, it could cause issues.
- **Mitigation:** Ensure `mix.exs` has `elixirc_paths` configured as `["lib"]` for prod and `["lib", "test/support"]` for test only. This is standard Elixir practice. Verify in the scaffold plan.
- **Validation time:** 2 minutes -- check `mix.exs` config.

### Risk 5: Registry Agent process crashes and loses all registered tools

- **Risk:** If the Agent process backing the registry crashes, all tool registrations are lost.
- **Impact:** Agents cannot look up tools until they are re-registered. In a running system, this could stall all tool execution.
- **Mitigation:** Add the registry to the application supervision tree (Scaffold Lead's responsibility) so it restarts automatically. On restart, tools will need to be re-registered. For Phase 1 this is acceptable. For Phase 3+, consider persisting the tool list to config or ETS with `:named_table` for crash survival.
- **Validation time:** 5 minutes -- kill the registry Agent, verify it restarts, verify tools need re-registration.

---

## Recommended API Surface

### `Cortex.Tool.Behaviour` (behaviour module)
- `@callback name() :: String.t()`
- `@callback description() :: String.t()`
- `@callback schema() :: map()`
- `@callback execute(args :: map()) :: {:ok, term()} | {:error, term()}`

### `Cortex.Tool.Executor`
- `run(tool_module, args, opts \\ []) :: {:ok, term()} | {:error, term()}` -- Execute a tool in an isolated process with timeout.

### `Cortex.Tool.Registry`
- `start_link(opts \\ []) :: {:ok, pid()}` -- Start the registry Agent.
- `register(tool_module) :: :ok | {:error, :invalid_tool}` -- Register a tool by module.
- `lookup(name) :: {:ok, module()} | {:error, :not_found}` -- Find a tool by name string.
- `list() :: [module()]` -- Return all registered tool modules.

### `Cortex.Tool.Supervisor`
- `child_spec(opts) :: Supervisor.child_spec()` -- Returns the Task.Supervisor child spec.

### `Cortex.Tool.Builtin.Shell`
- Implements `Cortex.Tool.Behaviour`. Name: `"shell"`.
- `execute(%{"command" => String.t(), "args" => [String.t()], "timeout_ms" => integer()}) :: {:ok, String.t()} | {:error, term()}`

---

## Folder Structure

```
lib/cortex/tool/
  behaviour.ex          # Tool behaviour callbacks (owned by Tool Runtime Lead)
  executor.ex           # Sandboxed execution engine (owned by Tool Runtime Lead)
  supervisor.ex         # Task.Supervisor child spec (owned by Tool Runtime Lead)
  registry.ex           # Agent-backed tool lookup (owned by Tool Runtime Lead)
  builtin/
    shell.ex            # Shell command tool (owned by Tool Runtime Lead)

test/cortex/tool/
  behaviour_test.exs    # Behaviour compliance tests
  executor_test.exs     # Executor unit tests
  registry_test.exs     # Registry unit tests
  integration_test.exs  # Cross-component integration
  builtin/
    shell_test.exs      # Shell tool tests

test/support/
  test_tools.ex         # Echo, Slow, Crasher, Killer, BadReturn tools
```

---

## Step-by-Step Task Plan (4-7 Small Commits)

### Task 1: Tool Behaviour and Supervisor

- **Outcome:** The tool behaviour contract is defined and the Task.Supervisor wrapper module exists.
- **Files to create:**
  - `lib/cortex/tool/behaviour.ex`
  - `lib/cortex/tool/supervisor.ex`
  - `test/cortex/tool/behaviour_test.exs`
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex/tool/behaviour_test.exs
  ```
- **Suggested commit message:** `feat(tool): add Tool behaviour contract and Task.Supervisor wrapper`

### Task 2: Tool Executor with Timeout and Crash Isolation

- **Outcome:** `Cortex.Tool.Executor.run/3` works -- spawns tasks under supervisor, enforces timeouts, catches crashes, returns clean tuples.
- **Files to create:**
  - `lib/cortex/tool/executor.ex`
  - `test/support/test_tools.ex` (Echo, Slow, Crasher, Killer, BadReturn)
  - `test/cortex/tool/executor_test.exs`
- **Verification:**
  ```bash
  mix test test/cortex/tool/executor_test.exs --trace
  ```
- **Suggested commit message:** `feat(tool): add Executor with sandboxed execution, timeout, and crash isolation`

### Task 3: Tool Registry

- **Outcome:** Agent-backed registry supports register, lookup, list. Validates behaviour compliance. Last-write-wins semantics with warning log on overwrite.
- **Files to create:**
  - `lib/cortex/tool/registry.ex`
  - `test/cortex/tool/registry_test.exs`
- **Verification:**
  ```bash
  mix test test/cortex/tool/registry_test.exs --trace
  ```
- **Suggested commit message:** `feat(tool): add Agent-backed Tool Registry with behaviour validation`

### Task 4: Built-in Shell Tool

- **Outcome:** Shell tool implements the behaviour, enforces command allowlist, handles exit codes, truncates output.
- **Files to create:**
  - `lib/cortex/tool/builtin/shell.ex`
  - `test/cortex/tool/builtin/shell_test.exs`
- **Verification:**
  ```bash
  mix test test/cortex/tool/builtin/shell_test.exs --trace
  ```
- **Suggested commit message:** `feat(tool): add built-in Shell tool with command allowlist`

### Task 5: Integration Tests and Benchmarks

- **Outcome:** End-to-end flow verified: supervisor + registry + executor + shell tool working together. Benchee benchmarks for executor overhead, concurrency, and registry lookup.
- **Files to create:**
  - `test/cortex/tool/integration_test.exs`
  - `bench/tool_bench.exs` (Benchee script)
- **Verification:**
  ```bash
  mix test test/cortex/tool/integration_test.exs --trace
  mix test test/cortex/tool/ --trace
  mix run bench/tool_bench.exs
  ```
- **Suggested commit message:** `test(tool): add integration tests and Benchee benchmarks for tool runtime`

---

## CLAUDE.md contributions (do NOT write the file; propose content)
### From Tool Runtime Lead

```markdown
## Tool Runtime

- Tools implement `Cortex.Tool.Behaviour` -- four callbacks: `name/0`, `description/0`, `schema/0`, `execute/1`.
- Execute tools via `Cortex.Tool.Executor.run/3` -- never call `tool.execute/1` directly from an agent.
- Executor spawns tasks under `Cortex.Tool.Supervisor` (Task.Supervisor) -- crash isolation is guaranteed.
- Default timeout is 30 seconds. Override with `run(tool, args, timeout: 60_000)`.
- Tool Registry is Agent-backed: `Cortex.Tool.Registry.register(MyTool)`, then `lookup("my_tool_name")`.
- Last-write-wins on duplicate tool names (enables hot-swap in dev).
- Shell tool: allowlist configured via `config :cortex, Cortex.Tool.Builtin.Shell, allowed_commands: [...]`.
- Run tool tests: `mix test test/cortex/tool/`
- Run benchmarks: `mix run bench/tool_bench.exs`
```

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

- **Tool Runtime -- Why Task.Supervisor + async_nolink?**
  - The core problem: agents invoke arbitrary tool code that might crash, hang, or misbehave.
  - We need isolation (crashes do not propagate) and timeouts (hangs are killed).
  - `Task.Supervisor.async_nolink` gives unlinked tasks -- crashes send `:DOWN` messages instead of killing the caller.
  - `Task.yield` + `Task.shutdown` gives clean timeout with guaranteed cleanup.
  - This is the idiomatic OTP pattern for "run untrusted code safely."

- **Tool Registry -- Why Agent instead of ETS?**
  - Simplicity wins for low-frequency access patterns.
  - Tools are registered at startup (rare writes), looked up when agents select tools (infrequent reads).
  - Agent serializes access through a single process -- correct by construction, no concurrency bugs.
  - ETS would be warranted at thousands of lookups per second; we are nowhere near that.

- **Shell Tool -- Why System.cmd over :os.cmd?**
  - `System.cmd/3` separates command from arguments -- no shell interpretation, no injection attacks.
  - `:os.cmd/1` passes a string to `/bin/sh -c` -- shell metacharacters are interpreted.
  - The allowlist is defense-in-depth: even with safe execution, we restrict which binaries can run.

---

## READY FOR APPROVAL
