defmodule Mix.Tasks.Cortex.Status do
  @shortdoc "Check Cortex system health"

  @moduledoc """
  Starts the Cortex application and runs health checks against all
  critical system components, printing the results.

  ## Usage

      mix cortex.status

  ## Checks

    * PubSub -- Phoenix.PubSub process
    * Supervisor -- DynamicSupervisor for agents
    * Tool Registry -- Agent-backed tool registry
    * Database -- SQLite via Ecto

  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    %{status: overall, checks: checks} = Cortex.Health.check()

    check_lines =
      Enum.map(
        [
          {"PubSub", checks.pubsub},
          {"Supervisor", checks.supervisor},
          {"Tool Registry", checks.tool_registry},
          {"Database", checks.repo}
        ],
        fn {name, healthy} ->
          indicator = if healthy, do: "[ok]", else: "[!!]"
          label = if healthy, do: "running", else: "DOWN"
          "  #{indicator} #{String.pad_trailing(name, 16)} #{label}"
        end
      )

    overall_indicator = status_indicator(overall)
    overall_label = Atom.to_string(overall)

    lines =
      ["", "Cortex System Status", ""] ++
        check_lines ++
        ["", "  #{overall_indicator} #{String.pad_trailing("Overall", 16)} #{overall_label}", ""]

    Mix.shell().info(Enum.join(lines, "\n"))

    if overall == :down do
      exit({:shutdown, 1})
    end
  end

  @spec status_indicator(:ok | :degraded | :down) :: String.t()
  defp status_indicator(:ok), do: "[ok]"
  defp status_indicator(:degraded), do: "[!!]"
  defp status_indicator(:down), do: "[!!]"
end
