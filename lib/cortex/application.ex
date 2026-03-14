defmodule Cortex.Application do
  @moduledoc """
  OTP Application for Cortex.

  Starts the supervision tree with five children in dependency order:

  1. Phoenix.PubSub — event broadcasting (must start before agents)
  2. Registry — agent name registration (must start before agents)
  3. DynamicSupervisor — spawns agent GenServers on demand
  4. Task.Supervisor — sandboxed tool execution
  5. Cortex.Tool.Registry — Agent-backed tool name lookup

  **Important:** PubSub and Registry must start before DynamicSupervisor
  because agent GenServers register in the Registry and broadcast events
  via PubSub during `init/1`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # PubSub must start first — agents broadcast events during init
      {Phoenix.PubSub, name: Cortex.PubSub},
      # Registry must start before DynamicSupervisor — agents register via via_tuple during init
      {Registry, keys: :unique, name: Cortex.Agent.Registry},
      # DynamicSupervisor for agent GenServers
      {DynamicSupervisor, name: Cortex.Agent.Supervisor, strategy: :one_for_one},
      # Task.Supervisor for sandboxed tool execution
      {Task.Supervisor, name: Cortex.Tool.Supervisor},
      # Agent-backed tool registry for name -> module lookup
      {Cortex.Tool.Registry, []}
    ]

    opts = [strategy: :one_for_one, name: Cortex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
