defmodule CortexWeb.ClusterLive do
  @moduledoc """
  LiveView page showing connected agents in real-time via the Gateway Registry.

  Displays agent registrations, heartbeats, status changes, and transport type
  (gRPC vs WebSocket). Subscribes to PubSub for live updates and refreshes
  heartbeat times every 5 seconds.
  """

  use CortexWeb, :live_view

  @refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      safe_subscribe_events()
      safe_subscribe_gateway()
      Process.send_after(self(), :refresh_heartbeats, @refresh_interval)
    end

    agents = safe_list_agents()

    {:ok,
     assign(socket,
       page_title: "Cluster",
       agents: agents,
       now: DateTime.utc_now()
     )}
  end

  # -- PubSub handlers --

  @impl true
  def handle_info(%{type: :agent_registered, payload: payload}, socket) do
    agent_id = Map.get(payload, :agent_id)

    agents =
      case safe_get_agent(agent_id) do
        {:ok, agent} ->
          [agent | reject_agent(socket.assigns.agents, agent_id)]

        _ ->
          socket.assigns.agents
      end

    name = Map.get(payload, :name, "unknown")

    {:noreply,
     socket
     |> assign(agents: agents, now: DateTime.utc_now())
     |> put_flash(:info, "Agent connected: #{name}")}
  end

  def handle_info(%{type: :agent_unregistered, payload: payload}, socket) do
    agent_id = Map.get(payload, :agent_id)
    name = Map.get(payload, :name, "unknown")

    agents = reject_agent(socket.assigns.agents, agent_id)

    {:noreply,
     socket
     |> assign(agents: agents, now: DateTime.utc_now())
     |> put_flash(:info, "Agent disconnected: #{name}")}
  end

  def handle_info(%{type: :agent_status_changed, payload: payload}, socket) do
    agent_id = Map.get(payload, :agent_id)
    new_status = Map.get(payload, :new_status)

    agents =
      Enum.map(socket.assigns.agents, fn agent ->
        if agent.id == agent_id, do: %{agent | status: new_status}, else: agent
      end)

    {:noreply, assign(socket, agents: agents)}
  end

  def handle_info(:refresh_heartbeats, socket) do
    Process.send_after(self(), :refresh_heartbeats, @refresh_interval)
    {:noreply, assign(socket, now: DateTime.utc_now())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-7xl mx-auto">
      <.header>
        Cluster
        <:subtitle>
          <span class="inline-flex items-center gap-2">
            Connected agents
            <span class="bg-cortex-900/60 text-cortex-300 text-xs font-medium px-2 py-0.5 rounded-full">
              {length(@agents)}
            </span>
          </span>
        </:subtitle>
      </.header>

      <%= if @agents == [] do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-12 text-center">
          <p class="text-gray-400 text-lg">No agents connected.</p>
          <p class="text-gray-600 text-sm mt-2">Start a sidecar to see agents appear.</p>
        </div>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
          <div
            :for={agent <- @agents}
            class="bg-gray-900 rounded-lg border border-gray-800 p-4 space-y-3"
          >
            <%!-- Header: name + transport badge --%>
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2 min-w-0">
                <span class="text-white font-medium truncate">{agent.name}</span>
                <span class={transport_badge_class(agent.transport)}>
                  {agent.transport}
                </span>
              </div>
              <span class={agent_status_badge_class(agent.status)}>
                {agent.status}
              </span>
            </div>

            <%!-- Role --%>
            <p class="text-sm text-gray-400">{agent.role || "—"}</p>

            <%!-- Capabilities --%>
            <%= if agent.capabilities != [] do %>
              <div class="flex flex-wrap gap-1">
                <span
                  :for={cap <- agent.capabilities}
                  class="bg-gray-800 text-gray-400 text-xs px-1.5 py-0.5 rounded"
                >
                  {cap}
                </span>
              </div>
            <% end %>

            <%!-- Metadata row --%>
            <div class="grid grid-cols-2 gap-2 text-xs">
              <div>
                <span class="text-gray-600">Last heartbeat</span>
                <p class="text-gray-300">{relative_time(agent.last_heartbeat, @now)}</p>
              </div>
              <div>
                <span class="text-gray-600">Registered</span>
                <p class="text-gray-300">{format_time(agent.registered_at)}</p>
              </div>
            </div>

            <%!-- Agent ID --%>
            <div class="text-xs">
              <span class="text-gray-600">ID:</span>
              <span class="text-gray-500 font-mono" title={agent.id}>
                {String.slice(agent.id, 0, 8)}&hellip;
              </span>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Private helpers --

  defp safe_subscribe_events do
    Cortex.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp safe_subscribe_gateway do
    Cortex.Gateway.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp safe_list_agents do
    Cortex.Gateway.Registry.list()
  rescue
    _ -> []
  end

  defp safe_get_agent(agent_id) do
    Cortex.Gateway.Registry.get(agent_id)
  rescue
    _ -> {:error, :not_found}
  end

  defp reject_agent(agents, agent_id) do
    Enum.reject(agents, fn a -> a.id == agent_id end)
  end

  defp transport_badge_class(:grpc) do
    "bg-blue-900/50 text-blue-300 text-xs px-1.5 py-0.5 rounded shrink-0"
  end

  defp transport_badge_class(:websocket) do
    "bg-green-900/50 text-green-300 text-xs px-1.5 py-0.5 rounded shrink-0"
  end

  defp transport_badge_class(_) do
    "bg-gray-800 text-gray-400 text-xs px-1.5 py-0.5 rounded shrink-0"
  end

  defp agent_status_badge_class(:idle) do
    "bg-blue-900/50 text-blue-300 text-xs px-2 py-0.5 rounded"
  end

  defp agent_status_badge_class(:working) do
    "bg-green-900/50 text-green-300 text-xs px-2 py-0.5 rounded"
  end

  defp agent_status_badge_class(:draining) do
    "bg-yellow-900/50 text-yellow-300 text-xs px-2 py-0.5 rounded"
  end

  defp agent_status_badge_class(:disconnected) do
    "bg-red-900/50 text-red-300 text-xs px-2 py-0.5 rounded"
  end

  defp agent_status_badge_class(_) do
    "bg-gray-800 text-gray-500 text-xs px-2 py-0.5 rounded"
  end

  defp relative_time(nil, _now), do: "—"

  defp relative_time(%DateTime{} = dt, now) do
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < 0 -> "just now"
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  defp relative_time(_, _now), do: "—"

  defp format_time(nil), do: "—"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: "—"
end
