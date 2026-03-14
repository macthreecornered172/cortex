defmodule Cortex.Agent.Supervisor do
  @moduledoc """
  Thin wrapper around `DynamicSupervisor` for managing agent GenServer processes.

  Agents are started on demand via `start_agent/1` and stopped via `stop_agent/1`.
  Each agent is registered in `Cortex.Agent.Registry` by its ID, enabling lookup
  by ID from anywhere in the system.

  The DynamicSupervisor uses a `:one_for_one` strategy with `:temporary` restart
  so that the orchestration layer (not the supervisor) controls retry logic.
  """

  alias Cortex.Agent.Config
  alias Cortex.Agent.Registry, as: AgentRegistry
  alias Cortex.Agent.Server

  @supervisor_name __MODULE__

  @doc """
  Starts a new agent process under the DynamicSupervisor.

  Accepts a `%Config{}` struct or a plain map (which will be validated and
  converted to a Config). Returns `{:ok, pid}` on success, or
  `{:error, reason}` if the child fails to start or config is invalid.
  """
  @spec start_agent(Config.t() | map()) :: {:ok, pid()} | {:error, term()}
  def start_agent(%Config{} = config) do
    DynamicSupervisor.start_child(@supervisor_name, {Server, config})
  end

  def start_agent(%{} = attrs) do
    case Config.new(attrs) do
      {:ok, config} -> start_agent(config)
      {:error, _} = err -> err
    end
  end

  @doc """
  Stops an agent by its ID.

  Looks up the agent's pid via the Registry, then terminates the child
  under the DynamicSupervisor. Returns `:ok` on success, or
  `{:error, :not_found}` if no agent is registered with the given ID.
  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(agent_id) when is_binary(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(@supervisor_name, pid)

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists all running agents as `{id, pid}` pairs.

  Delegates to `Cortex.Agent.Registry.all/0`.
  """
  @spec list_agents() :: [{String.t(), pid()}]
  def list_agents do
    AgentRegistry.all()
  end
end
