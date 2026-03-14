defmodule Mix.Tasks.Cortex.Run do
  @shortdoc "Run a Cortex orchestration from an orchestra.yaml file"

  @moduledoc """
  Runs a multi-team orchestration defined in an orchestra.yaml file.

  ## Usage

      mix cortex.run <config_path> [options]

  ## Options

    * `--dry-run` - Show execution plan without running
    * `--continue-on-error` - Continue to next tier even if a team fails
    * `--workspace` - Directory for .cortex/ workspace (default: current dir)

  ## Examples

      mix cortex.run orchestra.yaml
      mix cortex.run project/orchestra.yaml --dry-run
      mix cortex.run orchestra.yaml --continue-on-error --workspace /tmp/run

  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [dry_run: :boolean, continue_on_error: :boolean, workspace: :string],
        aliases: [d: :dry_run, c: :continue_on_error, w: :workspace]
      )

    Mix.Task.run("app.start")

    config_path = List.first(positional) || raise_usage()

    runner_opts = [
      dry_run: Keyword.get(opts, :dry_run, false),
      continue_on_error: Keyword.get(opts, :continue_on_error, false),
      workspace_path: Keyword.get(opts, :workspace, ".")
    ]

    Mix.shell().info("\n=> Cortex Orchestration Engine\n")

    case Cortex.Orchestration.Runner.run(config_path, runner_opts) do
      {:ok, %{status: :dry_run} = plan} ->
        Mix.shell().info(format_dry_run(plan))

      {:ok, summary} ->
        Mix.shell().info(format_summary(summary))

      {:error, {:tier_failed, tier_index, failures}} ->
        Mix.shell().error(
          "Orchestration failed at tier #{tier_index}: #{Enum.join(failures, ", ")}"
        )

        exit({:shutdown, 1})

      {:error, reasons} when is_list(reasons) ->
        Mix.shell().error("Orchestration failed:")

        Enum.each(reasons, fn reason ->
          Mix.shell().error("  - #{reason}")
        end)

        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Orchestration failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  @spec raise_usage() :: no_return()
  defp raise_usage do
    Mix.raise(
      "Usage: mix cortex.run <config_path> [--dry-run] [--continue-on-error] [--workspace DIR]"
    )
  end

  @spec format_dry_run(map()) :: String.t()
  defp format_dry_run(plan) do
    tier_lines =
      Enum.map(plan.tiers, fn tier ->
        team_names = Enum.map(tier.teams, & &1.name)

        team_details =
          Enum.map(tier.teams, fn t ->
            "      - #{t.name} (#{t.role}, model: #{t.model})"
          end)

        ["    Tier #{tier.tier}:  #{Enum.join(team_names, ", ")}" | team_details]
      end)
      |> List.flatten()

    lines =
      [
        "DRY RUN -- No agents will be spawned",
        "",
        "  Project: #{plan.project}",
        "  Teams:   #{plan.total_teams}",
        "  Tiers:   #{length(plan.tiers)}",
        ""
      ] ++ tier_lines

    Enum.join(lines, "\n")
  end

  @spec format_summary(map()) :: String.t()
  defp format_summary(summary) do
    status_label = if summary.status == :complete, do: "COMPLETE", else: "FAILED"

    wall_clock =
      if Map.has_key?(summary, :wall_clock_ms),
        do: Cortex.Orchestration.Summary.format_duration(summary.wall_clock_ms),
        else: "--"

    lines =
      [
        summary.summary,
        "",
        "  Wall clock: #{wall_clock}",
        "  Status:     #{status_label}"
      ]

    Enum.join(lines, "\n")
  end
end
