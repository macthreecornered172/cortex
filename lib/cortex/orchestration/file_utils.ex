defmodule Cortex.Orchestration.FileUtils do
  @moduledoc """
  Atomic file write utilities for orchestration workspace files.

  All state and registry writes go through `atomic_write/2` to prevent
  partial writes from corrupting JSON files. The pattern: write to a
  temporary `.tmp` sibling, then `File.rename/2` (which is atomic on
  POSIX systems when source and dest are on the same filesystem).
  """

  @doc """
  Atomically writes `content` to `path`.

  Writes to `path.tmp` first, then renames to `path`. This guarantees
  that readers never see a partially-written file.

  Returns `:ok` on success, or `{:error, reason}` if either the write
  or the rename fails.

  ## Parameters

    - `path` — the target file path (absolute or relative)
    - `content` — the binary content to write

  ## Examples

      iex> FileUtils.atomic_write("/tmp/state.json", ~s({"ok": true}))
      :ok

  """
  @spec atomic_write(Path.t(), binary()) :: :ok | {:error, term()}
  def atomic_write(path, content) when is_binary(path) and is_binary(content) do
    tmp_path = path <> ".tmp"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        # Best-effort cleanup of the tmp file
        File.rm(tmp_path)
        {:error, reason}
    end
  end
end
