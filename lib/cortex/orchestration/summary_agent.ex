defmodule Cortex.Orchestration.SummaryAgent do
  @moduledoc """
  Spawns a short-lived `claude -p` agent to produce an AI-generated run summary.

  Pre-reads workspace files (state.json, log tails, registry), embeds them
  in the prompt, and gets a structured analysis back. Uses haiku with
  max_turns 1 — no tool calls needed, pure synthesis.

  ## Usage

      SummaryAgent.generate("/path/to/project", run_name: "my-run")
      #=> {:ok, %{content: "...", generated_at: "...", filename: "..."}}

  The summary is also saved to `.cortex/summaries/` on disk so the
  dashboard can display it alongside any coordinator-generated summaries.
  """

  alias Cortex.Orchestration.Spawner

  require Logger

  @max_log_lines 50
  @max_log_files 10

  @doc """
  Generates an AI summary of the current run state.

  Reads workspace files, builds a context prompt, spawns `claude -p`
  with haiku, and returns the summary text. Also saves to disk.

  ## Options

    - `:run_name` — display name for the run (default: `"Untitled"`)
    - `:command` — override the claude command path (default: `"claude"`)
    - `:on_activity` — `fn name, activity -> ...` callback for tool use events
    - `:on_token_update` — `fn name, tokens -> ...` callback for token updates

  ## Returns

    - `{:ok, %{content: String.t(), generated_at: String.t(), filename: String.t()}}`
    - `{:error, term()}`
  """
  @spec generate(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate(workspace_path, opts \\ []) do
    cortex_path = Path.join(workspace_path, ".cortex")
    run_name = Keyword.get(opts, :run_name, "Untitled")
    log_path = Path.join([cortex_path, "logs", "summary-agent.log"])

    context = gather_context(cortex_path)
    prompt = build_prompt(run_name, context)

    spawn_opts = [
      team_name: "summary-agent",
      prompt: prompt,
      model: "haiku",
      max_turns: 1,
      permission_mode: "bypassPermissions",
      timeout_minutes: 2,
      command: Keyword.get(opts, :command, "claude"),
      cwd: workspace_path,
      log_path: log_path
    ]

    spawn_opts =
      spawn_opts
      |> maybe_add_callback(:on_activity, opts)
      |> maybe_add_callback(:on_token_update, opts)

    result = Spawner.spawn(spawn_opts)

    case result do
      {:ok, %{result: text, status: :success}} ->
        filename = save_to_disk(cortex_path, text)

        {:ok,
         %{
           content: text,
           generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
           filename: filename
         }}

      {:ok, %{result: text}} ->
        {:ok,
         %{
           content: text,
           generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
           filename: nil
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Context gathering --

  defp gather_context(cortex_path) do
    %{
      state: read_file(Path.join(cortex_path, "state.json")),
      registry: read_file(Path.join(cortex_path, "registry.json")),
      logs: read_log_tails(Path.join(cortex_path, "logs"))
    }
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp read_log_tails(logs_dir) do
    case File.ls(logs_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".log"))
        |> Enum.sort()
        |> Enum.take(@max_log_files)
        |> Enum.map(fn file ->
          path = Path.join(logs_dir, file)
          content = read_file(path) || ""

          lines =
            content
            |> String.split("\n")
            |> Enum.take(-@max_log_lines)
            |> Enum.join("\n")

          {file, lines}
        end)

      _ ->
        []
    end
  end

  # -- Prompt --

  defp build_prompt(run_name, context) do
    logs_section =
      context.logs
      |> Enum.map_join("\n\n", fn {file, lines} -> "### #{file}\n```\n#{lines}\n```" end)

    """
    You are a run analysis agent. Analyze the orchestration run data below and produce a concise summary.

    ## Run: #{run_name}

    ## State
    ```json
    #{context.state || "No state file found"}
    ```

    ## Registry
    ```json
    #{context.registry || "No registry file found"}
    ```

    ## Log Tails (last #{@max_log_lines} lines each)
    #{if logs_section == "", do: "No logs found", else: logs_section}

    ## Instructions
    Produce a summary covering:
    1. **Status Overview** — which teams are done, running, failed, or pending
    2. **Key Findings** — what each team produced or accomplished
    3. **Issues** — any failures, errors, rate limits, or stalls detected in the logs
    4. **Token Usage** — per-team token consumption from state.json
    5. **Recommendations** — next steps or concerns

    Keep the summary under 80 lines. Be direct and factual. Use markdown formatting.
    Do NOT use any tools. Just analyze the data provided above and write your summary.
    """
    |> String.trim()
  end

  # -- Persistence --

  defp maybe_add_callback(opts, key, source_opts) do
    case Keyword.get(source_opts, key) do
      nil -> opts
      cb -> Keyword.put(opts, key, cb)
    end
  end

  defp save_to_disk(cortex_path, content) do
    dir = Path.join(cortex_path, "summaries")
    File.mkdir_p!(dir)

    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%dT%H%M%S")

    filename = "#{timestamp}_ai_summary.md"
    path = Path.join(dir, filename)
    File.write!(path, content)
    filename
  rescue
    e ->
      Logger.warning("Failed to save AI summary to disk: #{inspect(e)}")
      nil
  end
end
