defmodule Cortex.Tool.Executor do
  @moduledoc """
  Sandboxed tool execution engine.

  Spawns tool executions as isolated tasks under `Cortex.Tool.Supervisor`
  (a `Task.Supervisor`), providing:

  - **Crash isolation** — tool failures never propagate to the calling process
  - **Timeout enforcement** — configurable per-execution timeout with guaranteed cleanup
  - **Clean error tuples** — all failure modes return tagged `{:error, reason}` tuples

  ## Usage

      # Basic execution with default timeout (30s)
      {:ok, result} = Cortex.Tool.Executor.run(MyTool, %{"input" => "hello"})

      # With custom timeout
      {:ok, result} = Cortex.Tool.Executor.run(MyTool, %{}, timeout: 5_000)

      # Error cases
      {:error, :timeout} = Cortex.Tool.Executor.run(SlowTool, %{}, timeout: 100)
      {:error, {:exception, _reason}} = Cortex.Tool.Executor.run(CrashingTool, %{})

  ## How it works

  1. Spawns a `Task.Supervisor.async_nolink/3` task (unlinked — crashes send `:DOWN` not crashes)
  2. Calls `Task.yield(task, timeout)` to wait for the result
  3. On success — returns the tool's result directly
  4. On timeout — `Task.shutdown(task, :brutal_kill)` and returns `{:error, :timeout}`
  5. On crash — returns `{:error, {:exception, reason}}`
  """

  @default_timeout 30_000
  @default_supervisor Cortex.Tool.Supervisor

  @doc """
  Execute a tool module in an isolated process with timeout enforcement.

  ## Arguments

  - `tool_module` — a module implementing `Cortex.Tool.Behaviour`
  - `args` — a map of arguments passed to `tool_module.execute/1`
  - `opts` — keyword list of options:
    - `:timeout` — milliseconds before the task is killed (default: `30_000`)
    - `:supervisor` — the Task.Supervisor to use (default: `Cortex.Tool.Supervisor`)

  ## Returns

  - `{:ok, result}` — tool executed successfully
  - `{:error, :timeout}` — tool exceeded the timeout and was killed
  - `{:error, {:exception, reason}}` — tool raised an exception or exited abnormally
  """
  @spec run(module(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(tool_module, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    supervisor = Keyword.get(opts, :supervisor, @default_supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        tool_module.execute(args)
      end)

    case Task.yield(task, timeout) do
      {:ok, {:ok, _result} = success} ->
        success

      {:ok, {:error, _reason} = error} ->
        error

      {:ok, other} ->
        # Tool returned a non-standard value (not {:ok, _} or {:error, _})
        {:error, {:bad_return, other}}

      nil ->
        # Timeout — kill the task and clean up
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}

      {:exit, reason} ->
        # Task crashed or was killed
        {:error, {:exception, reason}}
    end
  end
end
