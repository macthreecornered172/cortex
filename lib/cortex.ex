defmodule Cortex do
  @moduledoc """
  Top-level convenience module for the Cortex multi-agent orchestration system.

  Provides a simple API for starting, stopping, and listing agents. All
  functions delegate to the underlying subsystems (`Cortex.Agent.Supervisor`
  and `Cortex.Agent.Registry`).

  ## Quick start

      # Start an agent:
      {:ok, pid} = Cortex.start_agent(%{id: "my-agent", name: "Worker", role: "coder"})

      # List running agents:
      Cortex.list_agents()
      #=> [{"my-agent", #PID<0.123.0>}]

      # Stop an agent:
      Cortex.stop_agent("my-agent")
  """

  alias Cortex.Agent.Registry, as: AgentRegistry
  alias Cortex.Agent.Supervisor, as: AgentSupervisor

  @doc """
  Starts a new supervised agent process.

  Accepts a config map that is passed to `Cortex.Agent.Server.start_link/1`.
  Returns `{:ok, pid}` on success, or `{:error, reason}` if the agent fails
  to start.

  ## Examples

      {:ok, pid} = Cortex.start_agent(%{name: "analyzer", role: "researcher"})

  """
  @spec start_agent(map()) :: {:ok, pid()} | {:error, term()}
  defdelegate start_agent(config), to: AgentSupervisor

  @doc """
  Stops an agent by its ID.

  Returns `:ok` on success, or `{:error, :not_found}` if no agent is
  registered with the given ID.

  ## Examples

      :ok = Cortex.stop_agent("some-agent-id")

  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  defdelegate stop_agent(agent_id), to: AgentSupervisor

  @doc """
  Lists all running agents as `{id, pid}` pairs.

  ## Examples

      Cortex.list_agents()
      #=> [{"agent-1", #PID<0.123.0>}, {"agent-2", #PID<0.124.0>}]

  """
  @spec list_agents() :: [{String.t(), pid()}]
  defdelegate list_agents(), to: AgentRegistry, as: :all
end
