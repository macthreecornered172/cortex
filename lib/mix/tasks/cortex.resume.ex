defmodule Mix.Tasks.Cortex.Resume do
  @shortdoc "Resume dead teams in a Cortex orchestration run"

  @moduledoc """
  Resumes teams that died mid-run (rate limits, crashes, timeouts).

  Scans the `.cortex/` workspace for teams marked "running" that have no
  active process, extracts their session IDs from log files, and resumes
  each one using `claude --resume <session_id>`.

  ## Usage

      mix cortex.resume <workspace_path> [options]

  ## Options

    * `--auto-retry` - Automatically retry rate-limited teams after a delay
    * `--retry-delay` - Seconds to wait before retrying rate-limited teams (default: 60)
    * `--timeout` - Per-team timeout in minutes (default: 30)

  ## Examples

      mix cortex.resume examples/hackathon
      mix cortex.resume /path/to/project --retry-delay 120

  """

  use Mix.Task

  alias Cortex.Orchestration.Runner

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [auto_retry: :boolean, retry_delay: :integer, timeout: :integer],
        aliases: [r: :retry_delay, t: :timeout]
      )

    workspace_path = resolve_workspace(positional)
    validate_cortex_dir!(workspace_path)

    Mix.shell().info("Scanning #{workspace_path} for dead teams...")

    runner_opts = build_runner_opts(opts)

    case Runner.resume_run(workspace_path, runner_opts) do
      {:ok, results} when map_size(results) == 0 ->
        Mix.shell().info("No dead teams found. All teams are either completed or pending.")

      {:ok, results} ->
        print_results(results)

      {:error, reason} ->
        Mix.shell().error("Failed to resume: #{inspect(reason)}")
    end
  end

  defp resolve_workspace(positional) do
    case positional do
      [path | _] -> Path.expand(path)
      [] -> File.cwd!()
    end
  end

  defp validate_cortex_dir!(workspace_path) do
    cortex_dir = Path.join(workspace_path, ".cortex")

    unless File.dir?(cortex_dir) do
      Mix.shell().error("No .cortex/ directory found at #{workspace_path}")
      System.halt(1)
    end
  end

  defp build_runner_opts(opts) do
    [
      auto_retry: opts[:auto_retry] || false,
      retry_delay_ms: (opts[:retry_delay] || 60) * 1_000,
      timeout_minutes: opts[:timeout] || 30
    ]
  end

  defp print_results(results) do
    Mix.shell().info("\nResume results:")

    Enum.each(results, fn
      {team, {:ok, result}} ->
        Mix.shell().info(
          "  #{team}: #{result.status} (#{result.num_turns || 0} turns, $#{result.cost_usd || 0})"
        )

      {team, {:error, reason}} ->
        Mix.shell().error("  #{team}: FAILED - #{inspect(reason)}")
    end)
  end
end
