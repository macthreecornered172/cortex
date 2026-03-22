defmodule Cortex.Agent.ExternalSupervisor do
  @moduledoc """
  DynamicSupervisor for managing `ExternalAgent` GenServer processes.

  Each external agent is started on demand via `start_agent/1` and supervised
  with a `:temporary` restart strategy — the orchestration layer handles retries,
  not the supervisor.

  ## Usage

      {:ok, pid} = ExternalSupervisor.start_agent(name: "backend-worker")
      {:ok, pid} = ExternalSupervisor.find_agent("backend-worker")
      :ok = ExternalSupervisor.stop_agent("backend-worker")
      agents = ExternalSupervisor.list_agents()

  ExternalAgent processes register themselves in `Cortex.Agent.Registry` by name,
  enabling lookup without going through the supervisor.
  """

  use DynamicSupervisor

  alias Cortex.Agent.ExternalAgent
  alias Cortex.Agent.Registry, as: AgentRegistry

  @supervisor_name __MODULE__

  @doc """
  Starts the DynamicSupervisor.

  ## Options

    - `:name` -- supervisor name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @supervisor_name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts an `ExternalAgent` child under the DynamicSupervisor.

  Passes `opts` directly to `ExternalAgent.start_link/1`. The `:name` key
  is required.

  Returns `{:ok, pid}` on success, or `{:error, reason}` if the agent
  fails to start (e.g., sidecar not found in Gateway.Registry).
  """
  @spec start_agent(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(opts) when is_list(opts) do
    child_spec = {ExternalAgent, opts}

    case DynamicSupervisor.start_child(@supervisor_name, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, unwrap_reason(reason)}
    end
  end

  @doc """
  Looks up a running `ExternalAgent` by name via `Cortex.Agent.Registry`.

  Returns `{:ok, pid}` if found, or `:not_found` if no agent is registered
  with the given name.
  """
  @spec find_agent(String.t()) :: {:ok, pid()} | :not_found
  def find_agent(name) when is_binary(name) do
    AgentRegistry.lookup(name)
  end

  @doc """
  Stops a running `ExternalAgent` by name.

  Looks up the agent via `Cortex.Agent.Registry`, then terminates the child
  under the DynamicSupervisor.

  Returns `:ok` on success, or `{:error, :not_found}` if no agent is
  registered with the given name.
  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(name) when is_binary(name) do
    case AgentRegistry.lookup(name) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(@supervisor_name, pid)

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns all running `ExternalAgent` children as `[{name, pid}]` pairs.

  Delegates to `Cortex.Agent.Registry.all/0` and filters to only include
  processes that are children of this supervisor.
  """
  @spec list_agents() :: [{String.t(), pid()}]
  def list_agents do
    supervisor_children =
      DynamicSupervisor.which_children(@supervisor_name)
      |> Enum.map(fn {_, pid, _, _} -> pid end)
      |> MapSet.new()

    AgentRegistry.all()
    |> Enum.filter(fn {_name, pid} -> MapSet.member?(supervisor_children, pid) end)
  end

  # -- Private --

  # Unwrap nested stop reasons from DynamicSupervisor
  @spec unwrap_reason(term()) :: term()
  defp unwrap_reason({:shutdown, reason}), do: reason
  defp unwrap_reason(reason), do: reason
end
