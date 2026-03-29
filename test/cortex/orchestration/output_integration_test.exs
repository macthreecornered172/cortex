defmodule Cortex.Orchestration.OutputIntegrationTest do
  @moduledoc """
  Integration test verifying that the output store and workspace sync
  work end-to-end through the Runner pipeline.

  Uses the DB sandbox (via ConnCase-style setup) and a mock claude script
  to run a real orchestration, then checks:

  1. Team output is stored and retrievable via API
  2. Workspace files are synced to the output store
  3. The manifest is written on completion
  """
  use CortexWeb.ConnCase

  alias Cortex.Orchestration.Runner
  alias Cortex.Output.Store, as: OutputStore
  alias Cortex.Store

  @moduletag :orchestration

  setup do
    store_base =
      Path.join(
        System.tmp_dir!(),
        "cortex_output_int_#{:erlang.unique_integer([:positive])}"
      )

    Application.put_env(:cortex, Cortex.Output.Store.Local, base_path: store_base)
    on_exit(fn -> File.rm_rf!(store_base) end)

    %{store_base: store_base}
  end

  defp create_run_and_workspace do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "cortex_int_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    yaml = """
    name: "output-test"
    defaults:
      model: haiku
      max_turns: 5
      permission_mode: bypassPermissions
      timeout_minutes: 2
    teams:
      - name: writer
        lead:
          role: "Content Writer"
        tasks:
          - summary: "Write content"
    """

    yaml_path = Path.join(tmp_dir, "orchestra.yaml")
    File.write!(yaml_path, yaml)

    ndjson = """
    echo '{"type":"system","subtype":"init","session_id":"sess-int-001"}'
    echo '{"type":"result","subtype":"success","result":"# Full Document\\n\\nThis is the complete deliverable with lots of content.","cost_usd":0.10,"num_turns":2,"duration_ms":5000}'
    """

    mock_path = Path.join(tmp_dir, "mock_claude.sh")
    File.write!(mock_path, "#!/bin/bash\n" <> ndjson)
    File.chmod!(mock_path, 0o755)

    {tmp_dir, yaml_path, mock_path}
  end

  test "runner stores team output and syncs workspace", %{conn: conn} do
    {tmp_dir, yaml_path, mock_path} = create_run_and_workspace()

    try do
      # Create a run record first so we have a run_id
      {:ok, run} =
        Store.create_run(%{
          name: "output-test",
          status: "pending",
          team_count: 1,
          workspace_path: tmp_dir
        })

      assert {:ok, _summary} =
               Runner.run(yaml_path,
                 command: mock_path,
                 workspace_path: tmp_dir,
                 run_id: run.id
               )

      # 1. Team output should be stored
      team_run = Store.get_team_run(run.id, "writer")
      assert team_run != nil
      assert team_run.output_key != nil
      assert team_run.result_summary != nil

      # Verify output content via store
      assert {:ok, content} = OutputStore.get(team_run.output_key)
      assert content =~ "Full Document"
      assert content =~ "complete deliverable"

      # 2. Verify output is accessible via API
      conn = get(conn, "/api/runs/#{run.id}/teams/writer/output")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["content"] =~ "Full Document"
      assert data["size_bytes"] > 0

      # 3. Verify has_output flag in team listing
      conn = build_conn()
      conn = get(conn, "/api/runs/#{run.id}/teams")
      assert %{"data" => [team]} = json_response(conn, 200)
      assert team["has_output"] == true

      # 4. Workspace files should be synced
      # Check that state.json was synced
      state_key = OutputStore.build_workspace_key(run.id, "state.json")
      assert {:ok, state_json} = OutputStore.get(state_key)
      state = Jason.decode!(state_json)
      assert state["teams"]["writer"]["status"] == "done"

      # 5. Manifest should exist
      manifest_key = OutputStore.build_workspace_key(run.id, "_manifest.json")
      assert {:ok, manifest_json} = OutputStore.get(manifest_key)
      manifest = Jason.decode!(manifest_json)
      assert manifest["run_id"] == run.id
      assert manifest["file_count"] > 0

      file_paths = Enum.map(manifest["files"], & &1["path"])
      assert "state.json" in file_paths
      assert "registry.json" in file_paths

      # 6. Workspace API should list files
      conn = build_conn()
      conn = get(conn, "/api/runs/#{run.id}/workspace")
      assert %{"data" => ws_data} = json_response(conn, 200)
      assert ws_data["file_count"] > 0

      # 7. Individual workspace file retrieval
      conn = build_conn()
      conn = get(conn, "/api/runs/#{run.id}/workspace/state.json")
      assert response(conn, 200) =~ "writer"
    after
      File.rm_rf!(tmp_dir)
    end
  end
end
