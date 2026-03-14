defmodule Mix.Tasks.Cortex.Validate do
  @shortdoc "Validate an orchestra.yaml config file"

  @moduledoc """
  Loads and validates an orchestra YAML config file without executing it.

  Parses the YAML, runs all validations, and prints the result including
  team names, DAG tier structure, and any warnings or errors.

  ## Usage

      mix cortex.validate <config_path>

  ## Examples

      mix cortex.validate orchestra.yaml
      mix cortex.validate project/orchestra.yaml

  """

  use Mix.Task

  alias Cortex.Orchestration.Config.Loader
  alias Cortex.Orchestration.DAG

  @impl Mix.Task
  def run(args) do
    {_opts, positional, _invalid} = OptionParser.parse(args, switches: [])

    config_path = List.first(positional) || raise_usage()

    case Loader.load(config_path) do
      {:ok, config, warnings} ->
        print_valid(config, warnings)

      {:error, errors} ->
        print_invalid(errors)
        exit({:shutdown, 1})
    end
  end

  @spec raise_usage() :: no_return()
  defp raise_usage do
    Mix.raise("Usage: mix cortex.validate <config_path>")
  end

  @spec print_valid(Cortex.Orchestration.Config.t(), [String.t()]) :: :ok
  defp print_valid(config, warnings) do
    {:ok, tiers} = DAG.build_tiers(config.teams)

    tier_lines =
      tiers
      |> Enum.with_index()
      |> Enum.map(fn {team_names, index} ->
        "    Tier #{index}: #{Enum.join(team_names, ", ")}"
      end)

    warning_lines =
      case warnings do
        [] ->
          ["  Warnings: none"]

        warns ->
          ["  Warnings:"] ++ Enum.map(warns, fn w -> "    - #{w}" end)
      end

    lines =
      [
        "[ok] Config valid: #{config.name}",
        "  Teams: #{length(config.teams)} (#{Enum.map_join(config.teams, ", ", & &1.name)})",
        "  Tiers: #{length(tiers)}"
      ] ++ tier_lines ++ warning_lines

    Mix.shell().info(Enum.join(lines, "\n"))
  end

  @spec print_invalid([String.t()]) :: :ok
  defp print_invalid(errors) do
    lines =
      ["[error] Config invalid: #{length(errors)} error(s)"] ++
        Enum.map(errors, fn e -> "  - #{e}" end)

    Mix.shell().error(Enum.join(lines, "\n"))
  end
end
