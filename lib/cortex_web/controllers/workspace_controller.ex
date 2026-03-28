defmodule CortexWeb.WorkspaceController do
  @moduledoc """
  JSON API controller for retrieving workspace snapshots.

  Workspace files are periodically synced to the output store during a run.
  This controller provides access to the manifest (file listing) and
  individual file content.

  Exposes:
    GET  /api/runs/:run_id/workspace        — list synced workspace files
    GET  /api/runs/:run_id/workspace/*path   — fetch a specific file's content
  """
  use CortexWeb, :controller

  action_fallback(CortexWeb.FallbackController)

  alias Cortex.Output.Store, as: OutputStore
  alias Cortex.Store

  @doc "List all synced workspace files for a run (via manifest or key listing)."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"run_id" => run_id}) do
    case Store.get_run(run_id) do
      nil ->
        {:error, :not_found}

      _run ->
        json(conn, %{data: fetch_file_listing(run_id)})
    end
  end

  @doc "Fetch a specific workspace file's content."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"run_id" => run_id, "path" => path_parts}) do
    relative_path = Path.join(path_parts)
    key = OutputStore.build_workspace_key(run_id, relative_path)

    with run when not is_nil(run) <- Store.get_run(run_id),
         {:ok, content} <- OutputStore.get(key) do
      conn
      |> put_resp_content_type(content_type_for(relative_path))
      |> send_resp(200, content)
    else
      _ -> {:error, :not_found}
    end
  end

  # -- Private -----------------------------------------------------------------

  defp fetch_file_listing(run_id) do
    manifest_key = OutputStore.build_workspace_key(run_id, "_manifest.json")

    case OutputStore.get(manifest_key) do
      {:ok, content} ->
        Jason.decode!(content)

      {:error, :not_found} ->
        files = list_workspace_files(run_id)
        %{run_id: run_id, files: files}
    end
  end

  defp list_workspace_files(run_id) do
    prefix = "runs/#{run_id}/workspace/"

    case OutputStore.list_keys(prefix) do
      {:ok, keys} -> Enum.reject(keys, &String.ends_with?(&1, "_manifest.json"))
      _ -> []
    end
  end

  defp content_type_for(path) do
    cond do
      String.ends_with?(path, ".json") -> "application/json"
      String.ends_with?(path, ".log") -> "text/plain"
      String.ends_with?(path, ".md") -> "text/markdown"
      true -> "application/octet-stream"
    end
  end
end
