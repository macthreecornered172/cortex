defmodule Cortex.Orchestration.Spawner do
  @moduledoc """
  Facade for spawning `claude -p` processes.

  Delegates to `Cortex.Provider.CLI` for the actual spawning, NDJSON
  parsing, and `TeamResult` construction. This module is preserved as a
  backward-compatible entry point so existing callers (Executor, Reconciler,
  SessionRunners, LiveViews, Launcher) continue to work without changes.

  ## Options

    - `:team_name` — string, required. Identifies the team this run belongs to.
    - `:prompt` — string, required. The full prompt text passed to `claude -p`.
    - `:model` — string, default `"sonnet"`. The LLM model to use.
    - `:max_turns` — integer, default `200`. Maximum conversation turns.
    - `:permission_mode` — string, default `"acceptEdits"`. Permission mode flag.
    - `:timeout_minutes` — integer, default `30`. Kill the process after this many minutes.
    - `:log_path` — string or nil. If set, raw stdout is written to this file path.
    - `:command` — string, default `"claude"`. Override in tests with a mock script path.

  """

  alias Cortex.Orchestration.TeamResult
  alias Cortex.Provider.CLI

  @doc """
  Spawns a `claude -p` process (or mock command) and captures the result.

  Returns `{:ok, %TeamResult{}}` on success, `{:error, term()}` on failure.

  ## Examples

      iex> Spawner.spawn(team_name: "backend", prompt: "Build the API", command: "/path/to/mock")
      {:ok, %TeamResult{team: "backend", status: :success, ...}}

  """
  @spec spawn(keyword()) :: {:ok, TeamResult.t()} | {:error, term()}
  def spawn(opts) when is_list(opts) do
    CLI.run(opts)
  end

  @doc """
  Resumes a previous `claude -p` session using `--resume <session_id>`.

  Takes the same options as `spawn/1` plus:
    - `:session_id` — required. The session ID to resume.
    - `:prompt` — the continuation prompt (default: "continue where you left off").

  Returns `{:ok, %TeamResult{}}` on success, `{:error, term()}` on failure.
  """
  @spec resume(keyword()) :: {:ok, TeamResult.t()} | {:error, term()}
  def resume(opts) when is_list(opts) do
    CLI.resume(opts)
  end

  @doc """
  Extracts a session_id from an NDJSON log file.

  Reads the first line of the log looking for `{"type":"system","subtype":"init","session_id":"..."}`.
  Falls back to scanning the result line for session_id.

  Returns `{:ok, session_id}` or `:error`.
  """
  @spec extract_session_id_from_log(String.t()) :: {:ok, String.t()} | :error
  def extract_session_id_from_log(log_path) do
    case File.read(log_path) do
      {:ok, content} -> find_session_id_in_content(content)
      {:error, _} -> :error
    end
  end

  defp find_session_id_in_content(content) do
    content
    |> String.split("\n")
    |> Enum.find_value(:error, fn line ->
      extract_session_id_from_line(String.trim(line))
    end)
  end

  defp extract_session_id_from_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system", "subtype" => "init", "session_id" => sid}} ->
        {:ok, sid}

      {:ok, %{"type" => "result", "session_id" => sid}} when is_binary(sid) ->
        {:ok, sid}

      _ ->
        nil
    end
  end
end
