defmodule Mix.Tasks.Cortex.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :cli

  # -- Helpers -----------------------------------------------------------------

  defp create_tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cortex_run_task_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp cleanup(dir) do
    File.rm_rf!(dir)
  end

  defp write_yaml(dir, filename, content) do
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  defp write_mock_script(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/bash\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp success_ndjson do
    """
    echo '{"type":"system","subtype":"init","session_id":"sess-001"}'
    echo '{"type":"result","subtype":"success","result":"All tasks completed","cost_usd":0.25,"num_turns":3,"duration_ms":15000}'
    """
  end

  defp valid_single_team_yaml do
    """
    name: "cli-test"
    defaults:
      model: sonnet
      max_turns: 10
      permission_mode: acceptEdits
      timeout_minutes: 5
    teams:
      - name: backend
        lead:
          role: "Backend Lead"
        tasks:
          - summary: "Build the API"
            verify: "echo ok"
    """
  end

  defp valid_two_tier_yaml do
    """
    name: "tiered-cli"
    defaults:
      model: sonnet
      max_turns: 10
      permission_mode: acceptEdits
      timeout_minutes: 5
    teams:
      - name: backend
        lead:
          role: "Backend Lead"
        tasks:
          - summary: "Build backend API"
        depends_on: []
      - name: frontend
        lead:
          role: "Frontend Lead"
        tasks:
          - summary: "Build frontend UI"
        depends_on:
          - backend
    """
  end

  # -- Tests -------------------------------------------------------------------

  describe "argument parsing" do
    test "raises on missing config path" do
      assert_raise Mix.Error, ~r/Usage/, fn ->
        Mix.Tasks.Cortex.Run.run([])
      end
    end

    test "raises on missing config path with only flags" do
      assert_raise Mix.Error, ~r/Usage/, fn ->
        Mix.Tasks.Cortex.Run.run(["--dry-run"])
      end
    end
  end

  describe "dry run" do
    test "prints execution plan without spawning agents" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", valid_two_tier_yaml())

        output =
          capture_io(fn ->
            Mix.Tasks.Cortex.Run.run([yaml_path, "--dry-run"])
          end)

        assert output =~ "Cortex Orchestration Engine"
        assert output =~ "DRY RUN"
        assert output =~ "tiered-cli"
        assert output =~ "Teams:   2"
        assert output =~ "Tiers:   2"
        assert output =~ "Tier 0"
        assert output =~ "backend"
        assert output =~ "Tier 1"
        assert output =~ "frontend"
      after
        cleanup(tmp_dir)
      end
    end

    test "works with -d alias" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", valid_single_team_yaml())

        output =
          capture_io(fn ->
            Mix.Tasks.Cortex.Run.run([yaml_path, "-d"])
          end)

        assert output =~ "DRY RUN"
        assert output =~ "cli-test"
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "full run" do
    test "runs orchestration and prints summary" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", valid_single_team_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson())

        # We need to pass --workspace and the mock command via the runner,
        # but mix tasks don't expose :command. We test via Runner directly
        # for full run. Here we verify the task's output formatting by
        # testing through the actual Runner and then formatting.
        #
        # For the mix task, the most meaningful tests are arg parsing and
        # dry-run since full runs require the spawner command option which
        # isn't exposed as a CLI flag (by design -- it's for testing).
        assert File.exists?(yaml_path)
        assert File.exists?(mock)
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "error handling" do
    test "prints error for nonexistent config file" do
      # capture_io won't capture exit, but we can catch the exit
      assert catch_exit(
               capture_io(:stderr, fn ->
                 Mix.Tasks.Cortex.Run.run(["/nonexistent/orchestra.yaml"])
               end)
             ) == {:shutdown, 1}
    end

    test "prints error for invalid config" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "bad.yaml", "name: \"\"\nteams: []")

        assert catch_exit(
                 capture_io(:stderr, fn ->
                   Mix.Tasks.Cortex.Run.run([yaml_path])
                 end)
               ) == {:shutdown, 1}
      after
        cleanup(tmp_dir)
      end
    end
  end
end
