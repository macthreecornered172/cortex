defmodule Cortex.Agent.Registry do
  @moduledoc """
  Thin wrapper around Elixir's built-in `Registry` for agent process lookup.

  Agents register themselves using `via_tuple/1` when starting their GenServer.
  The Registry auto-cleans entries when the owning process dies — no manual
  deregistration needed.

  ## Usage

      # In Agent.Server.start_link:
      GenServer.start_link(__MODULE__, args, name: Cortex.Agent.Registry.via_tuple(agent_id))

      # Lookup by ID:
      {:ok, pid} = Cortex.Agent.Registry.lookup("some-uuid")

      # List all registered agents:
      agents = Cortex.Agent.Registry.all()
  """

  @registry_name __MODULE__

  @doc """
  Produces the `:via` tuple for GenServer naming.

  Pass this as the `:name` option to `GenServer.start_link/3` so that the
  agent registers itself in the Registry under the given `agent_id`.
  """
  @spec via_tuple(String.t()) :: {:via, Registry, {__MODULE__, String.t()}}
  def via_tuple(agent_id) when is_binary(agent_id) do
    {:via, Registry, {@registry_name, agent_id}}
  end

  @doc """
  Looks up an agent process by its ID.

  Returns `{:ok, pid}` if the agent is registered, or `:not_found` if no
  process is registered under the given ID.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :not_found
  def lookup(agent_id) when is_binary(agent_id) do
    case Registry.lookup(@registry_name, agent_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  @doc """
  Returns all registered agent `{id, pid}` pairs.
  """
  @spec all() :: [{String.t(), pid()}]
  def all do
    Registry.select(@registry_name, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end
end
