defmodule Cortex.InternalAgent.Launcher do
  @moduledoc """
  Spawn and stop lifecycle for internal `claude -p` agents.

  Provides three operations that replace the duplicated patterns across
  SummaryAgent, DebugAgent, DAG coordinator, and gossip coordinator:

  - `run/1`       — synchronous spawn (caller blocks until the agent finishes)
  - `run_async/1` — wraps `run/1` in `Task.async`, returns `Task.t() | nil`
  - `stop/1`      — yields 5 s then brutal-kills; safe with `nil`
  """

  alias Cortex.InternalAgent.SpawnConfig
  alias Cortex.Provider.CLI, as: ProviderCLI

  require Logger

  @doc """
  Synchronously spawns a `claude -p` agent and returns the result.

  Dispatches through the `Provider.CLI` start/run/stop lifecycle.
  Internal agents always use Provider.CLI (they have no per-agent
  provider config).
  """
  @spec run(SpawnConfig.t()) :: {:ok, map()} | {:error, term()}
  def run(%SpawnConfig{} = config) do
    provider_config = %{command: config.command, cwd: config.cwd}

    with {:ok, handle} <- ProviderCLI.start(provider_config) do
      try do
        ProviderCLI.run(handle, config.prompt, SpawnConfig.to_run_opts(config))
      after
        ProviderCLI.stop(handle)
      end
    end
  end

  @doc """
  Spawns a `claude -p` agent inside a `Task.async`.

  Returns `Task.t()` on success or `nil` if spawning raises.
  Intended for long-lived agents (coordinators) where the caller
  will `stop/1` the task later.
  """
  @spec run_async(SpawnConfig.t()) :: Task.t() | nil
  def run_async(%SpawnConfig{} = config) do
    Task.async(fn ->
      run(config)
    end)
  rescue
    e ->
      Logger.warning("Failed to spawn async agent #{config.team_name}: #{inspect(e)}")
      nil
  end

  @doc """
  Stops a running agent task.

  Yields for 5 seconds, then brutal-kills if the task hasn't finished.
  Safe to call with `nil` (no-op).
  """
  @spec stop(Task.t() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(task) do
    case Task.yield(task, 5_000) do
      {:ok, _result} -> :ok
      nil -> Task.shutdown(task, :brutal_kill)
    end

    :ok
  rescue
    _ -> :ok
  end
end
