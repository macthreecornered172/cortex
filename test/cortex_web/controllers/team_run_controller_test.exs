defmodule CortexWeb.TeamRunControllerTest do
  use CortexWeb.ConnCase

  alias Cortex.Output.Store, as: OutputStore
  alias Cortex.Store

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "cortex_ctrl_test_#{:erlang.unique_integer([:positive])}"
      )

    Application.put_env(:cortex, Cortex.Output.Store.Local, base_path: base)
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, run} = Store.create_run(%{name: "test-run", status: "completed", team_count: 1})

    {:ok, team_run} =
      Store.create_team_run(%{
        run_id: run.id,
        team_name: "strength",
        role: "strength coach",
        status: "completed",
        result_summary: "Built a workout plan"
      })

    %{run: run, team_run: team_run}
  end

  describe "GET /api/runs/:run_id/teams" do
    test "includes has_output flag (false when no output)", %{conn: conn, run: run} do
      conn = get(conn, "/api/runs/#{run.id}/teams")
      assert %{"data" => [team]} = json_response(conn, 200)
      assert team["has_output"] == false
    end

    test "includes has_output flag (true when output stored)", %{
      conn: conn,
      run: run,
      team_run: team_run
    } do
      key = OutputStore.build_key(run.id, "strength")
      :ok = OutputStore.put(key, "Full workout plan content")
      {:ok, _} = Store.update_team_run(team_run, %{output_key: key})

      conn = get(conn, "/api/runs/#{run.id}/teams")
      assert %{"data" => [team]} = json_response(conn, 200)
      assert team["has_output"] == true
    end
  end

  describe "GET /api/runs/:run_id/teams/:name" do
    test "returns team run with has_output", %{conn: conn, run: run} do
      conn = get(conn, "/api/runs/#{run.id}/teams/strength")
      assert %{"data" => team} = json_response(conn, 200)
      assert team["team_name"] == "strength"
      assert team["has_output"] == false
    end
  end

  describe "GET /api/runs/:run_id/teams/:name/output" do
    test "returns output content when available", %{conn: conn, run: run, team_run: team_run} do
      key = OutputStore.build_key(run.id, "strength")
      content = "# Full Workout Plan\n\n## Week 1\n\nBench press 3x10..."
      :ok = OutputStore.put(key, content)
      {:ok, _} = Store.update_team_run(team_run, %{output_key: key})

      conn = get(conn, "/api/runs/#{run.id}/teams/strength/output")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["content"] == content
      assert data["team_name"] == "strength"
      assert data["run_id"] == run.id
      assert data["size_bytes"] == byte_size(content)
    end

    test "returns 404 when team has no output_key", %{conn: conn, run: run} do
      conn = get(conn, "/api/runs/#{run.id}/teams/strength/output")
      assert json_response(conn, 404)
    end

    test "returns 404 for nonexistent team", %{conn: conn, run: run} do
      conn = get(conn, "/api/runs/#{run.id}/teams/nonexistent/output")
      assert json_response(conn, 404)
    end

    test "returns 404 for nonexistent run", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      conn = get(conn, "/api/runs/#{fake_id}/teams/strength/output")
      assert json_response(conn, 404)
    end

    test "returns 404 when output_key set but file missing", %{
      conn: conn,
      run: run,
      team_run: team_run
    } do
      {:ok, _} = Store.update_team_run(team_run, %{output_key: "runs/ghost/teams/gone/output"})
      conn = get(conn, "/api/runs/#{run.id}/teams/strength/output")
      assert json_response(conn, 404)
    end
  end
end
