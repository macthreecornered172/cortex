defmodule CortexWeb.WorkspaceControllerTest do
  use CortexWeb.ConnCase

  alias Cortex.Output.Store, as: OutputStore
  alias Cortex.Store

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "cortex_ws_ctrl_test_#{:erlang.unique_integer([:positive])}"
      )

    Application.put_env(:cortex, Cortex.Output.Store.Local, base_path: base)
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, run} = Store.create_run(%{name: "test-run", status: "completed", team_count: 1})

    %{run: run}
  end

  describe "GET /api/runs/:run_id/workspace" do
    test "returns manifest when available", %{conn: conn, run: run} do
      manifest = %{
        run_id: run.id,
        file_count: 2,
        synced_at: "2026-03-28T12:00:00Z",
        files: [
          %{path: "state.json", size_bytes: 42, synced_at: "2026-03-28T12:00:00Z"},
          %{path: "results/backend.json", size_bytes: 100, synced_at: "2026-03-28T12:00:00Z"}
        ]
      }

      manifest_key = OutputStore.build_workspace_key(run.id, "_manifest.json")
      :ok = OutputStore.put(manifest_key, Jason.encode!(manifest))

      conn = get(conn, "/api/runs/#{run.id}/workspace")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["file_count"] == 2
      assert length(data["files"]) == 2
    end

    test "falls back to list_keys when no manifest", %{conn: conn, run: run} do
      key = OutputStore.build_workspace_key(run.id, "state.json")
      :ok = OutputStore.put(key, ~s({"project":"test"}))

      conn = get(conn, "/api/runs/#{run.id}/workspace")
      assert %{"data" => data} = json_response(conn, 200)
      assert is_list(data["files"])
    end

    test "returns empty files for run with no workspace", %{conn: conn, run: run} do
      conn = get(conn, "/api/runs/#{run.id}/workspace")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["files"] == []
    end

    test "returns 404 for nonexistent run", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      conn = get(conn, "/api/runs/#{fake_id}/workspace")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/runs/:run_id/workspace/*path" do
    test "returns file content", %{conn: conn, run: run} do
      key = OutputStore.build_workspace_key(run.id, "state.json")
      content = ~s({"project":"test","teams":{}})
      :ok = OutputStore.put(key, content)

      conn = get(conn, "/api/runs/#{run.id}/workspace/state.json")
      assert response(conn, 200) == content
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "returns nested file content", %{conn: conn, run: run} do
      key = OutputStore.build_workspace_key(run.id, "results/backend.json")
      content = ~s({"status":"done"})
      :ok = OutputStore.put(key, content)

      conn = get(conn, "/api/runs/#{run.id}/workspace/results/backend.json")
      assert response(conn, 200) == content
    end

    test "returns log files as text/plain", %{conn: conn, run: run} do
      key = OutputStore.build_workspace_key(run.id, "logs/run-1/backend.log")
      :ok = OutputStore.put(key, "ndjson line 1\nndjson line 2\n")

      conn = get(conn, "/api/runs/#{run.id}/workspace/logs/run-1/backend.log")
      assert response(conn, 200) =~ "ndjson line 1"
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    end

    test "returns 404 for nonexistent file", %{conn: conn, run: run} do
      conn = get(conn, "/api/runs/#{run.id}/workspace/nonexistent.json")
      assert json_response(conn, 404)
    end

    test "returns 404 for nonexistent run", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      conn = get(conn, "/api/runs/#{fake_id}/workspace/state.json")
      assert json_response(conn, 404)
    end
  end
end
