defmodule Cortex.Provider.CLI do
  @moduledoc """
  CLI provider implementation for `claude -p` processes.

  Implements the `Cortex.Provider` behaviour, delegating process management
  to `Cortex.SpawnBackend.Local` and owning:

  - CLI argument construction (`-p`, `--resume`, `--output-format`, etc.)
  - NDJSON stream parsing (session init, result, usage, activity events)
  - Token accumulation across streamed usage messages
  - Activity extraction from tool-use content blocks
  - Log file management (open, write, close)
  - Callback invocation (`on_token_update`, `on_activity`, `on_port_opened`)
  - `TeamResult` construction from the final result line

  ## Provider Lifecycle

      {:ok, handle} = Provider.CLI.start(%{command: "claude"})
      {:ok, result} = Provider.CLI.run(handle, "Build the API", team_name: "backend")
      :ok = Provider.CLI.stop(handle)

  ## Convenience API

  For backward compatibility, `run/1` and `resume/1` accept a flat keyword
  list (same as the original `Spawner.spawn/1`) and handle the full lifecycle
  internally.

  """

  @behaviour Cortex.Provider

  alias Cortex.Orchestration.TeamResult
  alias Cortex.SpawnBackend.Local

  require Logger

  @default_model "sonnet"
  @default_max_turns 200
  @default_permission_mode "acceptEdits"
  @default_timeout_minutes 30
  @default_command "claude"

  # Guard: never allow spawning the real `claude` binary in test env.
  # Tests must always pass an explicit `:command` pointing to a mock script.
  if Mix.env() == :test do
    defp guard_real_claude!(command) do
      basename = command |> Path.basename()

      if basename == "claude" do
        raise RuntimeError, """
        Attempted to spawn real `claude` binary in test environment!

        All tests must pass an explicit `:command` option pointing to a mock script.
        This guard prevents runaway Claude sessions from `mix test`.

        Got command: #{inspect(command)}
        """
      end

      :ok
    end
  else
    defp guard_real_claude!(_command), do: :ok
  end

  # -- Provider Behaviour Callbacks --------------------------------------------

  @doc """
  Initializes CLI provider state from config.

  ## Config Keys

    - `:command` — CLI executable name or path (default: `"claude"`)
    - `:cwd` — working directory for the spawned process (default: `nil`)

  Returns `{:ok, handle}` where handle contains the resolved command and cwd.
  """
  @impl Cortex.Provider
  @spec start(Cortex.Provider.config()) :: {:ok, Cortex.Provider.handle()} | {:error, term()}
  def start(config) when is_map(config) do
    command = Map.get(config, :command, @default_command)
    guard_real_claude!(command)
    cwd = Map.get(config, :cwd)
    {:ok, %{command: command, cwd: cwd}}
  end

  def start(config) when is_list(config) do
    command = Keyword.get(config, :command, @default_command)
    guard_real_claude!(command)
    cwd = Keyword.get(config, :cwd)
    {:ok, %{command: command, cwd: cwd}}
  end

  @doc """
  Executes a prompt against the CLI backend via the Provider behaviour.

  Builds CLI args, spawns a `claude -p` process via `SpawnBackend.Local`,
  collects and parses the NDJSON output stream, and returns a `TeamResult`.

  ## Run Options

    - `:team_name` — string, required
    - `:model` — string, default `"sonnet"`
    - `:max_turns` — integer, default `200`
    - `:permission_mode` — string, default `"acceptEdits"`
    - `:timeout_minutes` — number, default `30`
    - `:log_path` — string or nil
    - `:session_id` — string or nil (if set, resumes a previous session)
    - `:on_token_update` — callback `(team_name, tokens -> any)` or nil
    - `:on_activity` — callback `(team_name, activity -> any)` or nil
    - `:on_port_opened` — callback `(team_name, os_pid -> any)` or nil

  """
  @impl Cortex.Provider
  @spec run(Cortex.Provider.handle(), String.t(), Cortex.Provider.run_opts()) ::
          {:ok, TeamResult.t()} | {:error, term()}
  def run(handle, prompt, opts) when is_map(handle) and is_list(opts) do
    team_name = Keyword.fetch!(opts, :team_name)
    model = Keyword.get(opts, :model, @default_model)
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    permission_mode = Keyword.get(opts, :permission_mode, @default_permission_mode)
    timeout_minutes = Keyword.get(opts, :timeout_minutes, @default_timeout_minutes)
    log_path = Keyword.get(opts, :log_path)
    session_id = Keyword.get(opts, :session_id)
    on_token_update = Keyword.get(opts, :on_token_update)
    on_activity = Keyword.get(opts, :on_activity)

    system_prompt = Keyword.get(opts, :system_prompt)

    args =
      if session_id do
        build_resume_args(session_id, prompt)
      else
        build_args(prompt, model, max_turns, permission_mode)
      end

    args = if system_prompt, do: args ++ ["--system-prompt", system_prompt], else: args

    timeout_ms = round(timeout_minutes * 60 * 1_000)

    log_device = open_log_device(log_path)

    try do
      {:ok, backend_handle} =
        Local.spawn(
          command: handle.command,
          args: args,
          cwd: handle.cwd,
          timeout_ms: timeout_ms
        )

      notify_port_opened(Keyword.get(opts, :on_port_opened), team_name, backend_handle)

      state = initial_state(team_name, on_token_update, on_activity)

      handler = build_handler(log_device, team_name)

      final_state = Local.collect(backend_handle, state, handler)

      build_result(final_state)
    after
      close_log_device(log_device)
    end
  end

  @doc """
  Resumes a previous CLI session by session ID.

  Options must include `:session_id` and `:team_name`.
  """
  @impl Cortex.Provider
  @spec resume(Cortex.Provider.handle(), Cortex.Provider.run_opts()) ::
          {:ok, TeamResult.t()} | {:error, term()}
  def resume(handle, opts) when is_map(handle) and is_list(opts) do
    _session_id = Keyword.fetch!(opts, :session_id)
    prompt = Keyword.get(opts, :prompt, "continue where you left off")

    run(handle, prompt, opts)
  end

  @doc """
  Releases CLI provider resources.

  No-op for CLI since the provider is stateless between runs.
  """
  @impl Cortex.Provider
  @spec stop(Cortex.Provider.handle()) :: :ok
  def stop(_handle), do: :ok

  # -- Convenience API (flat keyword opts, for Spawner facade) -----------------

  @doc """
  Convenience function: runs a prompt using a flat keyword list.

  Accepts the same keyword options as the original `Spawner.spawn/1`.
  Handles the full `start/1` -> `run/3` -> `stop/1` lifecycle internally.

  ## Options

    - `:team_name` — string, required
    - `:prompt` — string, required
    - `:model` — string, default `"sonnet"`
    - `:max_turns` — integer, default `200`
    - `:permission_mode` — string, default `"acceptEdits"`
    - `:timeout_minutes` — number, default `30`
    - `:log_path` — string or nil
    - `:command` — string, default `"claude"`
    - `:cwd` — string or nil
    - `:on_token_update` — callback or nil
    - `:on_activity` — callback or nil
    - `:on_port_opened` — callback or nil

  """
  @spec run(keyword()) :: {:ok, TeamResult.t()} | {:error, term()}
  def run(opts) when is_list(opts) do
    command = Keyword.get(opts, :command, @default_command)
    cwd = Keyword.get(opts, :cwd)
    prompt = Keyword.fetch!(opts, :prompt)

    {:ok, handle} = start(%{command: command, cwd: cwd})

    try do
      run(handle, prompt, opts)
    after
      stop(handle)
    end
  end

  @doc """
  Convenience function: resumes a session using a flat keyword list.

  Accepts the same options as `run/1` plus `:session_id` (required).
  """
  @spec resume(keyword()) :: {:ok, TeamResult.t()} | {:error, term()}
  def resume(opts) when is_list(opts) do
    command = Keyword.get(opts, :command, @default_command)
    cwd = Keyword.get(opts, :cwd)

    {:ok, handle} = start(%{command: command, cwd: cwd})

    try do
      resume(handle, opts)
    after
      stop(handle)
    end
  end

  # -- CLI Argument Building ---------------------------------------------------

  @spec build_args(String.t(), String.t(), pos_integer(), String.t()) :: [String.t()]
  defp build_args(prompt, model, max_turns, permission_mode) do
    [
      "-p",
      prompt,
      "--output-format",
      "stream-json",
      "--verbose",
      "--model",
      model,
      "--max-turns",
      to_string(max_turns),
      "--permission-mode",
      permission_mode
    ]
  end

  @spec build_resume_args(String.t(), String.t()) :: [String.t()]
  defp build_resume_args(session_id, prompt) do
    [
      "--resume",
      session_id,
      "-p",
      prompt,
      "--output-format",
      "stream-json",
      "--verbose"
    ]
  end

  # -- Collect Loop State & Handler -------------------------------------------

  defp initial_state(team_name, on_token_update, on_activity) do
    %{
      team_name: team_name,
      buffer: "",
      session_id: nil,
      result_line: nil,
      collected_output: "",
      tokens: %{
        input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: 0,
        cache_creation_tokens: 0
      },
      on_token_update: on_token_update,
      on_activity: on_activity,
      exit_event: nil
    }
  end

  defp build_handler(log_device, _team_name) do
    fn event, state ->
      case event do
        {:data, data} ->
          write_to_log(log_device, data)
          new_state = process_data(data, state)
          {:cont, new_state}

        {:exit, 0} ->
          {final_session_id, final_result_line, _, _} =
            parse_remaining(state.buffer, state.session_id, state.result_line)

          {:halt,
           %{
             state
             | session_id: final_session_id,
               result_line: final_result_line,
               exit_event: {:exit, 0}
           }}

        {:exit, code} ->
          {:halt, %{state | exit_event: {:exit, code}}}

        :timeout ->
          {:halt, %{state | exit_event: :timeout}}

        {:port_died, _collected} ->
          {:halt, %{state | exit_event: {:port_died, state.collected_output}}}
      end
    end
  end

  defp process_data(data, state) do
    {lines, new_buffer} = extract_lines(state.buffer <> data)

    {new_session_id, new_result_line, usage_deltas, activities} =
      parse_lines(lines, state.session_id, state.result_line)

    new_tokens = accumulate_tokens(state.tokens, usage_deltas)
    safe_notify_tokens(state.on_token_update, state.team_name, state.tokens, new_tokens)
    safe_notify_activities(state.on_activity, state.team_name, activities)

    # Notify when session_id is first captured
    if new_session_id && state.session_id == nil && state.on_activity do
      try do
        state.on_activity.(state.team_name, %{
          type: :session_started,
          session_id: new_session_id
        })
      rescue
        _ -> :ok
      end
    end

    # Keep last 2KB of output for error diagnosis
    new_collected =
      String.slice(state.collected_output <> data, -2048, 2048)

    %{
      state
      | buffer: new_buffer,
        session_id: new_session_id,
        result_line: new_result_line,
        tokens: new_tokens,
        collected_output: new_collected
    }
  end

  # -- Result Building --------------------------------------------------------

  defp build_result(%{exit_event: {:exit, 0}} = state) do
    build_team_result(state.team_name, state.session_id, state.result_line)
  end

  defp build_result(%{exit_event: {:exit, code}} = state) do
    {:error, {:exit_code, code, state.collected_output}}
  end

  defp build_result(%{exit_event: :timeout} = state) do
    {:ok, %TeamResult{team: state.team_name, status: :timeout, session_id: state.session_id}}
  end

  defp build_result(%{exit_event: {:port_died, collected}}) do
    {:error, {:port_died, collected}}
  end

  @spec build_team_result(String.t(), String.t() | nil, map() | nil) ::
          {:ok, TeamResult.t()} | {:error, :no_result_line}
  defp build_team_result(_team_name, _session_id, nil) do
    {:error, :no_result_line}
  end

  defp build_team_result(team_name, session_id, result_map) do
    result_text = Map.get(result_map, "result", "")
    status = detect_status(result_map, result_text)
    cost = Map.get(result_map, "total_cost_usd") || Map.get(result_map, "cost_usd")

    usage = Map.get(result_map, "usage", %{})
    input_tokens = Map.get(usage, "input_tokens", 0)
    output_tokens = Map.get(usage, "output_tokens", 0)
    cache_read_tokens = Map.get(usage, "cache_read_input_tokens", 0)
    cache_creation_tokens = Map.get(usage, "cache_creation_input_tokens", 0)

    {:ok,
     %TeamResult{
       team: team_name,
       status: status,
       result: Map.get(result_map, "result"),
       cost_usd: cost,
       input_tokens: input_tokens,
       output_tokens: output_tokens,
       cache_read_tokens: cache_read_tokens,
       cache_creation_tokens: cache_creation_tokens,
       num_turns: Map.get(result_map, "num_turns"),
       duration_ms: Map.get(result_map, "duration_ms"),
       session_id: session_id || Map.get(result_map, "session_id")
     }}
  end

  @spec detect_status(map(), String.t() | nil) :: TeamResult.status()
  defp detect_status(result_map, result_text) do
    subtype = Map.get(result_map, "subtype", "success")

    cond do
      is_binary(result_text) and String.contains?(result_text, "rate_limit_error") ->
        :rate_limited

      subtype == "success" ->
        :success

      subtype == "error_max_turns" ->
        :success

      true ->
        :error
    end
  end

  # -- NDJSON Parsing ----------------------------------------------------------

  @spec extract_lines(String.t()) :: {[String.t()], String.t()}
  defp extract_lines(data) do
    case String.split(data, "\n") do
      [single] ->
        {[], single}

      parts ->
        {lines, [remainder]} = Enum.split(parts, -1)
        {lines, remainder}
    end
  end

  @spec parse_lines([String.t()], String.t() | nil, map() | nil) ::
          {String.t() | nil, map() | nil, [map()], [map()]}
  defp parse_lines(lines, session_id, result_line) do
    Enum.reduce(lines, {session_id, result_line, [], []}, fn line, {sid, res, usages, acts} ->
      {new_sid, new_res, usage, activity} = parse_ndjson_line(String.trim(line), sid, res)
      usages = if usage, do: [usage | usages], else: usages
      acts = if activity, do: [activity | acts], else: acts
      {new_sid, new_res, usages, acts}
    end)
  end

  @spec parse_remaining(String.t(), String.t() | nil, map() | nil) ::
          {String.t() | nil, map() | nil, [map()], [map()]}
  defp parse_remaining("", session_id, result_line), do: {session_id, result_line, [], []}

  defp parse_remaining(buffer, session_id, result_line) do
    {sid, res, usage, activity} = parse_ndjson_line(String.trim(buffer), session_id, result_line)
    usages = if usage, do: [usage], else: []
    acts = if activity, do: [activity], else: []
    {sid, res, usages, acts}
  end

  @spec parse_ndjson_line(String.t(), String.t() | nil, map() | nil) ::
          {String.t() | nil, map() | nil, map() | nil, map() | nil}
  defp parse_ndjson_line("", session_id, result_line), do: {session_id, result_line, nil, nil}

  defp parse_ndjson_line(line, session_id, result_line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result"} = parsed} ->
        {session_id, parsed, nil, nil}

      {:ok, %{"type" => "system", "subtype" => "init", "session_id" => sid}} ->
        {sid, result_line, nil, nil}

      {:ok, parsed} ->
        usage = extract_usage(parsed)
        activity = extract_activity(parsed)
        {session_id, result_line, usage, activity}

      {:error, _} ->
        # Non-JSON line (e.g. stderr interleaved) — skip
        {session_id, result_line, nil, nil}
    end
  end

  # -- Usage Extraction --------------------------------------------------------

  @spec extract_usage(map()) :: map() | nil
  defp extract_usage(%{"message" => %{"usage" => usage}}) when is_map(usage), do: usage
  defp extract_usage(%{"usage" => usage}) when is_map(usage), do: usage
  defp extract_usage(_), do: nil

  @spec accumulate_tokens(map(), [map()]) :: map()
  defp accumulate_tokens(tokens, []), do: tokens

  defp accumulate_tokens(tokens, usage_deltas) do
    Enum.reduce(usage_deltas, tokens, fn usage, acc ->
      %{
        input_tokens: acc.input_tokens + Map.get(usage, "input_tokens", 0),
        output_tokens: acc.output_tokens + Map.get(usage, "output_tokens", 0),
        cache_read_tokens: acc.cache_read_tokens + Map.get(usage, "cache_read_input_tokens", 0),
        cache_creation_tokens:
          acc.cache_creation_tokens + Map.get(usage, "cache_creation_input_tokens", 0)
      }
    end)
  end

  # -- Activity Extraction -----------------------------------------------------

  @spec extract_activity(map()) :: map() | nil
  defp extract_activity(%{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    tool_blocks =
      content
      |> Enum.filter(fn block -> is_map(block) and Map.get(block, "type") == "tool_use" end)

    tools = Enum.map(tool_blocks, fn block -> Map.get(block, "name", "unknown") end)
    details = Enum.map(tool_blocks, &tool_detail/1)

    if tools != [] do
      %{type: :tool_use, tools: tools, details: details}
    else
      nil
    end
  end

  defp extract_activity(%{
         "type" => "content_block_start",
         "content_block" => %{"type" => "tool_use", "name" => name}
       }) do
    %{type: :tool_use, tools: [name], details: [nil]}
  end

  defp extract_activity(_), do: nil

  @spec tool_detail(map()) :: String.t() | nil
  defp tool_detail(%{"name" => name, "input" => input}) when is_map(input) do
    tool_detail_for(name, input)
  end

  defp tool_detail(_), do: nil

  defp tool_detail_for("Bash", input), do: input |> Map.get("command", "") |> truncate_detail(80)
  defp tool_detail_for("Read", input), do: input |> Map.get("file_path", "") |> Path.basename()
  defp tool_detail_for("Write", input), do: input |> Map.get("file_path", "") |> Path.basename()
  defp tool_detail_for("Edit", input), do: input |> Map.get("file_path", "") |> Path.basename()
  defp tool_detail_for("Grep", input), do: input |> Map.get("pattern", "") |> truncate_detail(50)
  defp tool_detail_for("Glob", input), do: input |> Map.get("pattern", "") |> truncate_detail(50)

  defp tool_detail_for("Agent", input),
    do: input |> Map.get("description", "") |> truncate_detail(50)

  defp tool_detail_for("WebSearch", input),
    do: input |> Map.get("query", "") |> truncate_detail(50)

  defp tool_detail_for("WebFetch", input), do: input |> Map.get("url", "") |> truncate_detail(60)
  defp tool_detail_for(_, _input), do: nil

  @spec truncate_detail(String.t(), pos_integer()) :: String.t() | nil
  defp truncate_detail("", _max), do: nil

  defp truncate_detail(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end

  # -- Callback Notifications --------------------------------------------------

  @spec safe_notify_activities(function() | nil, String.t(), [map()]) :: :ok
  defp safe_notify_activities(nil, _team_name, _activities), do: :ok
  defp safe_notify_activities(_callback, _team_name, []), do: :ok

  defp safe_notify_activities(callback, team_name, activities) do
    Enum.each(activities, fn activity ->
      callback.(team_name, activity)
    end)

    :ok
  rescue
    _ -> :ok
  end

  @spec safe_notify_tokens(function() | nil, String.t(), map(), map()) :: :ok
  defp safe_notify_tokens(nil, _team_name, _old, _new), do: :ok
  defp safe_notify_tokens(_callback, _team_name, same, same), do: :ok

  defp safe_notify_tokens(callback, team_name, _old_tokens, new_tokens) do
    callback.(team_name, new_tokens)
    :ok
  rescue
    _ -> :ok
  end

  defp notify_port_opened(nil, _team_name, _handle), do: :ok

  defp notify_port_opened(callback, team_name, %Local.Handle{os_pid: os_pid}) do
    callback.(team_name, os_pid)
    :ok
  rescue
    _ -> :ok
  end

  # -- Log File Management -----------------------------------------------------

  @spec open_log_device(String.t() | nil) :: File.io_device() | nil
  defp open_log_device(nil), do: nil

  defp open_log_device(path) when is_binary(path) do
    path |> Path.dirname() |> File.mkdir_p!()

    case File.open(path, [:append, :binary]) do
      {:ok, device} ->
        device

      {:error, reason} ->
        Logger.warning("Failed to open log file #{path}: #{inspect(reason)}")
        nil
    end
  end

  @spec close_log_device(File.io_device() | nil) :: :ok
  defp close_log_device(nil), do: :ok
  defp close_log_device(device), do: File.close(device)

  @spec write_to_log(File.io_device() | nil, binary()) :: :ok
  defp write_to_log(nil, _data), do: :ok
  defp write_to_log(device, data), do: IO.binwrite(device, data)
end
