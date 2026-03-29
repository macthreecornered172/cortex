defmodule Cortex.Orchestration.WorkspaceSync do
  @moduledoc """
  Periodically snapshots the `.cortex/` workspace to the output store.

  Started alongside each orchestration run. Walks the workspace directory
  on a configurable interval, detects changed files via modification times,
  and uploads them to the output store under `runs/<run_id>/workspace/...`.

  Follows the `OutboxWatcher` pattern: unlinked GenServer with
  `Process.send_after/3` polling, auto-stops on `:run_completed`.

  ## Options

    - `:run_id` — required. The orchestration run ID.
    - `:workspace_path` — required. The project root (`.cortex/` is appended).
    - `:interval_ms` — poll interval in ms (default from config or 30 000).
    - `:max_file_bytes` — max file size to sync (default from config or 50 MB).

  ## Configuration

      config :cortex, Cortex.Orchestration.WorkspaceSync,
        interval_ms: 30_000,
        max_file_bytes: 50_000_000

  """

  use GenServer

  alias Cortex.Output.Store, as: OutputStore

  require Logger

  @default_interval_ms 30_000
  @default_max_file_bytes 50_000_000

  # -- Public API --------------------------------------------------------------

  @doc """
  Starts the sync process, NOT linked to the caller.

  Use this so the sync survives if the executor crashes — that's the
  whole point.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc "Starts the sync process linked to the caller."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Performs a final synchronous sync and writes a manifest.

  Call this before marking the run as completed to ensure all files
  are captured.
  """
  @spec final_sync(pid()) :: :ok
  def final_sync(pid) do
    GenServer.call(pid, :final_sync, 60_000)
  end

  @doc "Gracefully stops the sync process."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # -- Callbacks ---------------------------------------------------------------

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    config = Application.get_env(:cortex, __MODULE__, [])

    interval_ms =
      Keyword.get(opts, :interval_ms, Keyword.get(config, :interval_ms, @default_interval_ms))

    max_file_bytes =
      Keyword.get(
        opts,
        :max_file_bytes,
        Keyword.get(config, :max_file_bytes, @default_max_file_bytes)
      )

    cortex_path = Path.join(workspace_path, ".cortex")

    safe_subscribe()

    state = %{
      run_id: run_id,
      cortex_path: cortex_path,
      interval_ms: interval_ms,
      max_file_bytes: max_file_bytes,
      mtimes: %{}
    }

    # Immediate first sync
    schedule_tick(0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = do_sync(state)
    schedule_tick(state.interval_ms)
    {:noreply, new_state}
  end

  def handle_info(%{type: :run_completed}, state) do
    new_state = do_sync(state)
    write_manifest(new_state)
    {:stop, :normal, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:final_sync, _from, state) do
    # Clear mtime cache to force a full re-upload. Periodic ticks may
    # have cached an mtime for a file (e.g. state.json) that was since
    # rewritten within the same second — same mtime, different content.
    new_state = do_sync(%{state | mtimes: %{}})
    write_manifest(new_state)
    {:reply, :ok, new_state}
  end

  # -- Sync Logic --------------------------------------------------------------

  @spec do_sync(map()) :: map()
  defp do_sync(%{cortex_path: cortex_path} = state) when is_binary(cortex_path) do
    if not File.dir?(cortex_path), do: throw(:skip)

    %{run_id: run_id, mtimes: mtimes, max_file_bytes: max_bytes} = state

    syncable =
      cortex_path
      |> walk_files()
      |> Enum.reject(fn path -> skip_file?(Path.relative_to(path, cortex_path)) end)

    new_mtimes =
      Enum.reduce(syncable, mtimes, fn abs_path, acc ->
        sync_file(abs_path, Path.relative_to(abs_path, cortex_path), run_id, acc, max_bytes)
      end)

    %{state | mtimes: new_mtimes}
  catch
    :skip -> state
  end

  @spec sync_file(String.t(), String.t(), String.t(), map(), pos_integer()) :: map()
  defp sync_file(abs_path, relative, run_id, mtimes, max_bytes) do
    case File.stat(abs_path) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        cached_mtime = Map.get(mtimes, relative)

        if mtime != cached_mtime do
          upload_file(abs_path, relative, run_id, size, max_bytes)
          Map.put(mtimes, relative, mtime)
        else
          mtimes
        end

      {:error, _} ->
        mtimes
    end
  end

  @spec upload_file(String.t(), String.t(), String.t(), non_neg_integer(), pos_integer()) :: :ok
  defp upload_file(abs_path, relative, run_id, size, max_bytes) do
    key = OutputStore.build_workspace_key(run_id, relative)

    content =
      if size > max_bytes do
        read_tail(abs_path, max_bytes)
      else
        case File.read(abs_path) do
          {:ok, data} -> data
          {:error, _} -> nil
        end
      end

    if content do
      case OutputStore.put(key, content) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("WorkspaceSync: failed to upload #{relative}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @spec read_tail(String.t(), pos_integer()) :: binary() | nil
  defp read_tail(path, max_bytes) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, device} <- File.open(path, [:read, :binary]) do
      offset = max(size - max_bytes, 0)
      :file.position(device, offset)
      result = IO.binread(device, max_bytes)
      File.close(device)
      if is_binary(result), do: result, else: nil
    else
      _ -> nil
    end
  end

  # -- Manifest ----------------------------------------------------------------

  @spec write_manifest(map()) :: :ok
  defp write_manifest(%{run_id: run_id, mtimes: mtimes, cortex_path: cortex_path}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    files =
      Enum.map(mtimes, fn {relative, _mtime} ->
        abs_path = Path.join(cortex_path, relative)

        size =
          case File.stat(abs_path) do
            {:ok, %File.Stat{size: s}} -> s
            _ -> 0
          end

        %{path: relative, size_bytes: size, synced_at: now}
      end)
      |> Enum.sort_by(& &1.path)

    manifest = %{
      run_id: run_id,
      file_count: length(files),
      synced_at: now,
      files: files
    }

    key = OutputStore.build_workspace_key(run_id, "_manifest.json")

    case OutputStore.put(key, Jason.encode!(manifest, pretty: true)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("WorkspaceSync: manifest write failed: #{inspect(reason)}")
    end

    :ok
  end

  # -- Helpers -----------------------------------------------------------------

  @spec walk_files(String.t()) :: [String.t()]
  defp walk_files(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &expand_entry(dir, &1))
      {:error, _} -> []
    end
  end

  defp expand_entry(dir, entry) do
    path = Path.join(dir, entry)
    if File.dir?(path), do: walk_files(path), else: [path]
  end

  @spec skip_file?(String.t()) :: boolean()
  defp skip_file?(relative) do
    String.ends_with?(relative, ".tmp")
  end

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp safe_subscribe do
    Cortex.Events.subscribe()
  rescue
    _ -> :ok
  end
end
