defmodule Cortex.SpawnBackend.Local do
  @moduledoc """
  Local spawn backend using Erlang ports.

  Implements the `Cortex.SpawnBackend` behaviour for locally spawned OS
  processes. Manages the lifecycle: opening the port, streaming output,
  checking liveness, and cleaning up.

  This module owns the transport layer — it knows about ports, exit statuses,
  and OS process signals. It does **not** parse the data flowing through the
  port; that responsibility belongs to the provider (e.g. `Provider.CLI`).

  ## Handle

  The opaque `t:handle/0` struct is returned by `spawn/1` and must be passed
  to all other functions. It carries the port reference, OS pid, and timeout
  timer reference.

  ## APIs

  Two output consumption strategies are provided:

  - `stream/1` — behaviour callback, returns a lazy `Enumerable.t()` of
    binary chunks (for future generic consumption)
  - `collect/3` — callback-based receive loop with accumulator, used by
    `Provider.CLI` for real-time NDJSON parsing with inline notifications
  """

  @behaviour Cortex.SpawnBackend

  require Logger

  # If no output received for this long, check if the port process is still alive
  @idle_check_ms :timer.minutes(2)

  defmodule Handle do
    @moduledoc false
    @enforce_keys [:port, :timer_ref]
    defstruct [:port, :timer_ref, :os_pid]

    @type t :: %__MODULE__{
            port: port(),
            timer_ref: reference(),
            os_pid: non_neg_integer() | nil
          }
  end

  @type handle :: Handle.t()

  @type event ::
          {:data, binary()}
          | {:exit, non_neg_integer()}
          | :timeout
          | {:port_died, binary()}

  # -- Public API --------------------------------------------------------------

  @doc """
  Opens an Erlang port to the given command with args.

  Returns an opaque handle for use with `collect/3`, `stop/1`, and `status/1`.

  ## Options

    - `:command` — command string or path (required)
    - `:args` — list of string arguments (required)
    - `:cwd` — working directory for the spawned process (optional)
    - `:timeout_ms` — kill the process after this many milliseconds (required)

  """
  @impl Cortex.SpawnBackend
  @spec spawn(keyword()) :: {:ok, handle()}
  def spawn(opts) when is_list(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.fetch!(opts, :args)
    cwd = Keyword.get(opts, :cwd)
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)

    command_path = resolve_command(command)
    port = open_port(command_path, args, cwd)

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    timer_ref = Process.send_after(self(), {:spawn_backend_timeout, port}, timeout_ms)

    handle = %Handle{port: port, timer_ref: timer_ref, os_pid: os_pid}
    {:ok, handle}
  end

  @doc """
  Returns a lazy stream of binary chunks from the port's stdout.

  The stream terminates when the port exits or the timeout fires.
  Exit status and timeout are signalled as tagged tuples in the stream:

    - `{:data, binary}` — raw stdout data
    - `{:exit, code}` — port exited with status code
    - `{:timeout}` — timeout fired, port killed
    - `{:port_died}` — port died silently

  The caller must call `stop/1` after consuming the stream.
  """
  @impl Cortex.SpawnBackend
  @spec stream(handle()) :: {:ok, Enumerable.t()}
  def stream(%Handle{} = handle) do
    stream =
      Stream.resource(
        fn -> {:open, handle} end,
        fn
          {:done, _handle} ->
            {:halt, :done}

          {:open, %Handle{port: port, timer_ref: timer_ref} = h} ->
            receive do
              {^port, {:data, data}} ->
                {[{:data, data}], {:open, h}}

              {^port, {:exit_status, code}} ->
                Process.cancel_timer(timer_ref)
                {[{:exit, code}], {:done, h}}

              {:spawn_backend_timeout, ^port} ->
                kill_port(port)
                Process.cancel_timer(timer_ref)
                {[{:timeout}], {:done, h}}
            after
              @idle_check_ms ->
                if port_alive?(port) do
                  {[], {:open, h}}
                else
                  Process.cancel_timer(timer_ref)
                  {[{:port_died}], {:done, h}}
                end
            end
        end,
        fn _ -> :ok end
      )

    {:ok, stream}
  end

  @doc """
  Runs a receive loop on the handle's port, invoking `handler` for each event.

  The handler receives an `t:event/0` and an accumulator, and must return
  `{:cont, new_acc}` to continue or `{:halt, new_acc}` to stop early.

  Returns the final accumulator when the port exits, times out, or the
  handler halts.

  ## Events

    - `{:data, binary}` — a chunk of stdout data from the port
    - `{:exit, code}` — the port process exited with the given status code
    - `:timeout` — the timeout timer fired; the port has been killed
    - `{:port_died, collected}` — the port process died silently (no exit_status)

  """
  @spec collect(handle(), acc, (event(), acc -> {:cont, acc} | {:halt, acc})) :: acc
        when acc: term()
  def collect(%Handle{} = handle, acc, handler) when is_function(handler, 2) do
    collect_loop(handle, acc, handler, "")
  end

  @doc """
  Stops the port process and cancels the timeout timer.

  Idempotent — safe to call multiple times or on an already-closed port.
  """
  @impl Cortex.SpawnBackend
  @spec stop(handle()) :: :ok
  def stop(%Handle{port: port, timer_ref: timer_ref}) do
    Process.cancel_timer(timer_ref)
    kill_port(port)
    :ok
  end

  @doc """
  Checks whether the port's OS process is still running.
  """
  @impl Cortex.SpawnBackend
  @spec status(handle()) :: :running | :done
  def status(%Handle{port: port}) do
    if port_alive?(port), do: :running, else: :done
  end

  # -- Private -----------------------------------------------------------------

  defp collect_loop(%Handle{port: port, timer_ref: timer_ref} = handle, acc, handler, collected) do
    receive do
      {^port, {:data, data}} ->
        new_collected = truncate_collected(collected <> data)

        case handler.({:data, data}, acc) do
          {:cont, new_acc} -> collect_loop(handle, new_acc, handler, new_collected)
          {:halt, new_acc} -> new_acc
        end

      {^port, {:exit_status, code}} ->
        Process.cancel_timer(timer_ref)
        {_, final_acc} = handler.({:exit, code}, acc)
        final_acc

      {:spawn_backend_timeout, ^port} ->
        kill_port(port)
        Process.cancel_timer(timer_ref)
        {_, final_acc} = handler.(:timeout, acc)
        final_acc
    after
      @idle_check_ms ->
        if port_alive?(port) do
          Logger.debug("SpawnBackend.Local idle check: port still alive, continuing")
          collect_loop(handle, acc, handler, collected)
        else
          Logger.warning("SpawnBackend.Local idle check: port process died silently")
          Process.cancel_timer(timer_ref)
          {_, final_acc} = handler.({:port_died, collected}, acc)
          final_acc
        end
    end
  end

  # Keep last 2KB of collected output for error diagnosis
  defp truncate_collected(data) when byte_size(data) > 2048 do
    binary_part(data, byte_size(data) - 2048, 2048)
  end

  defp truncate_collected(data), do: data

  @spec resolve_command(String.t()) :: charlist()
  defp resolve_command(command) do
    case System.find_executable(command) do
      nil -> to_charlist(command)
      path -> to_charlist(path)
    end
  end

  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  @stripped_env_vars ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]

  @spec open_port(charlist(), [String.t()], String.t() | nil) :: port()
  defp open_port(command_path, args, cwd) do
    # Strip CLAUDECODE env vars so child claude processes don't refuse to start.
    # Use {key, false} to explicitly unset vars in the child process environment.
    env =
      System.get_env()
      |> Map.drop(@stripped_env_vars)
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      |> Kernel.++(Enum.map(@stripped_env_vars, &{String.to_charlist(&1), false}))

    # Use /bin/sh wrapper to redirect stdin from /dev/null.
    # claude -p hangs if stdin stays open (it waits for input).
    escaped_args = Enum.map(args, &shell_escape/1)
    shell_cmd = Enum.join([to_string(command_path) | escaped_args], " ") <> " </dev/null"

    port_opts = [:binary, :exit_status, :use_stdio, {:args, ["-c", shell_cmd]}, {:env, env}]
    port_opts = if cwd, do: [{:cd, String.to_charlist(cwd)} | port_opts], else: port_opts

    Port.open({:spawn_executable, ~c"/bin/sh"}, port_opts)
  end

  @spec port_alive?(port()) :: boolean()
  defp port_alive?(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end

      nil ->
        false
    end
  rescue
    ArgumentError -> false
  end

  @spec kill_port(port()) :: :ok
  defp kill_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end
end
