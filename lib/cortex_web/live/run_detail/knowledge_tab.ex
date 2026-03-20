defmodule CortexWeb.RunDetail.KnowledgeTab do
  @moduledoc """
  Knowledge tab for RunDetailLive — Gossip mode only.

  Renders round progress, topology description, convergence
  entries, and knowledge details. Stateless function component.
  """
  use Phoenix.Component

  import CortexWeb.MeshComponents, only: [communication_graph: 1, message_flow_summary: 1]

  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the gossip knowledge tab content.
  """
  attr(:run, :map, required: true)
  attr(:team_runs, :list, required: true)
  attr(:gossip_round, :any, default: nil)
  attr(:gossip_knowledge, :any, default: nil)
  attr(:message_flows, :map, default: %{flows: [], total: 0, by_agent: %{}})
  attr(:knowledge_view, :string, default: "list")
  attr(:selected_graph_node, :string, default: nil)

  def knowledge_tab(assigns) do
    gossip_info = Helpers.parse_gossip_info(assigns.run)
    visible_runs = Enum.reject(assigns.team_runs, & &1.internal)
    assigns = assign(assigns, gossip_info: gossip_info, visible_runs: visible_runs)

    ~H"""
    <div>
      <%= if @gossip_info do %>
        <div class="bg-gray-900 rounded-lg border border-purple-900/50 p-4 mb-6">
          <h2 class="text-sm font-medium text-purple-400 uppercase tracking-wider mb-3">Knowledge Exchange</h2>
          <p class="text-sm text-gray-400 mb-4">
            {Helpers.topology_description(@gossip_info.topology, length(@team_runs))}
            — {@gossip_info.rounds} rounds, {@gossip_info.exchange_interval}s apart.
          </p>

          <div class="flex items-center gap-4 mb-4">
            <div class="flex-1">
              <%= if @gossip_round do %>
                <div class="flex items-center justify-between text-xs text-gray-500 mb-1">
                  <span>Round {@gossip_round.current} of {@gossip_round.total}</span>
                  <span class={if @gossip_round.current >= @gossip_round.total, do: "text-green-400", else: "text-purple-400"}>
                    {if @gossip_round.current >= @gossip_round.total, do: "Complete", else: "Exchanging"}
                  </span>
                </div>
                <div class="h-2 bg-gray-800 rounded-full overflow-hidden">
                  <div
                    class="h-full bg-purple-500 rounded-full transition-all duration-500"
                    style={"width: #{min(round(@gossip_round.current / max(@gossip_round.total, 1) * 100), 100)}%"}
                  />
                </div>
              <% else %>
                <div class="flex items-center justify-between text-xs text-gray-500 mb-1">
                  <span>{@gossip_info.rounds} rounds configured</span>
                  <span class={if @run.status == "completed", do: "text-green-400", else: "text-gray-500"}>
                    {if @run.status == "completed", do: "Complete", else: "Waiting"}
                  </span>
                </div>
                <div class="h-2 bg-gray-800 rounded-full overflow-hidden">
                  <div
                    class={"h-full bg-#{if @run.status == "completed", do: "green", else: "gray"}-600 rounded-full"}
                    style={"width: #{if @run.status == "completed", do: "100", else: "0"}%"}
                  />
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- View toggle --%>
        <div class="flex items-center gap-1 mb-4 bg-gray-900 rounded-lg border border-gray-800 p-1 w-fit">
          <button
            phx-click="set_knowledge_view"
            phx-value-view="list"
            class={[
              "px-3 py-1.5 text-sm rounded-md transition-colors",
              if(@knowledge_view == "list", do: "bg-gray-700 text-white", else: "text-gray-400 hover:text-gray-300")
            ]}
          >
            Knowledge
          </button>
          <button
            phx-click="set_knowledge_view"
            phx-value-view="graph"
            class={[
              "px-3 py-1.5 text-sm rounded-md transition-colors",
              if(@knowledge_view == "graph", do: "bg-gray-700 text-white", else: "text-gray-400 hover:text-gray-300")
            ]}
          >
            Graph
          </button>
        </div>

        <%!-- Graph view --%>
        <div :if={@knowledge_view == "graph"}>
          <%= if length(@visible_runs) >= 2 do %>
            <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4">
              <.communication_graph
                agents={Enum.map(@visible_runs, fn tr -> %{name: tr.team_name, status: tr.status, role: tr.role} end)}
                message_flows={@message_flows}
                selected_node={@selected_graph_node}
                run_status={@run.status}
                theme="purple"
              />
            </div>
          <% end %>
        </div>

        <%!-- Knowledge view (default) --%>
        <div :if={@knowledge_view == "list"}>
        <div :if={@message_flows.total > 0} class="mb-4">
          <.message_flow_summary message_flows={@message_flows} theme="purple" />
        </div>
        <%= if @gossip_knowledge do %>
          <div class="bg-gray-900 rounded-lg border border-purple-900/50 p-4 mb-6">
            <div class="flex items-center gap-3 mb-3">
              <h3 class="text-sm font-medium text-purple-400 uppercase tracking-wider">Knowledge Discovered</h3>
              <span class="text-xs text-gray-500">{@gossip_knowledge.total_entries} entries across {map_size(@gossip_knowledge.by_topic)} topics</span>
            </div>
            <div class="flex flex-wrap gap-2 mb-3">
              <span
                :for={{topic, count} <- Enum.sort_by(@gossip_knowledge.by_topic, fn {_t, c} -> -c end)}
                class="bg-purple-900/30 text-purple-300 text-xs px-2 py-1 rounded"
              >
                {topic} <span class="text-purple-500">({count})</span>
              </span>
            </div>
            <%= if @gossip_knowledge.top_entries != [] do %>
              <div class="space-y-2 max-h-64 overflow-y-auto">
                <div :for={entry <- @gossip_knowledge.top_entries} class="bg-gray-950 rounded p-2">
                  <div class="flex items-center gap-2 mb-1">
                    <span class="text-purple-300 text-xs font-medium">{entry.topic}</span>
                    <span class="text-gray-600 text-xs">from {entry.source}</span>
                    <span class={["text-xs ml-auto", Helpers.confidence_label_class(entry.confidence)]}>
                      {Helpers.confidence_label(entry.confidence)}
                    </span>
                  </div>
                  <p class="text-gray-400 text-xs">{Helpers.truncate(entry.content, 150)}</p>
                </div>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
            <p class="text-gray-500 text-sm">No knowledge data yet. Knowledge entries appear here after gossip rounds complete.</p>
          </div>
        <% end %>
        </div>
      <% else %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
          <p class="text-gray-500 text-sm">No gossip configuration found.</p>
        </div>
      <% end %>
    </div>
    """
  end
end
