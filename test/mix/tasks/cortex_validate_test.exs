defmodule Mix.Tasks.Cortex.ValidateTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cortex.Validate

  import ExUnit.CaptureIO

  @moduletag :cli

  # -- Helpers -----------------------------------------------------------------

  defp create_tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cortex_validate_task_test_#{:erlang.unique_integer([:positive])}"
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

  defp valid_yaml do
    """
    name: "my-project"
    defaults:
      model: sonnet
      max_turns: 100
      permission_mode: acceptEdits
      timeout_minutes: 30
    teams:
      - name: backend
        lead:
          role: "Backend Lead"
        tasks:
          - summary: "Build REST API"
            details: "Create endpoints"
            verify: "go build ./..."
        depends_on: []
      - name: frontend
        lead:
          role: "Frontend Lead"
        tasks:
          - summary: "Build UI"
            details: "Create React components"
            verify: "npm test"
        depends_on:
          - backend
      - name: devops
        lead:
          role: "DevOps Lead"
        tasks:
          - summary: "Set up CI/CD"
            details: "Configure pipelines"
            verify: "echo ok"
        depends_on:
          - backend
      - name: integration
        lead:
          role: "Integration Lead"
        tasks:
          - summary: "Run integration tests"
            details: "End-to-end verification"
            verify: "mix test --only integration"
        depends_on:
          - frontend
          - devops
    """
  end

  defp invalid_yaml_unknown_dep do
    """
    name: "broken"
    teams:
      - name: frontend
        lead:
          role: "Frontend Lead"
        tasks:
          - summary: "Build UI"
        depends_on:
          - backnd
    """
  end

  defp invalid_yaml_empty_teams do
    """
    name: "empty"
    teams: []
    """
  end

  # -- Tests -------------------------------------------------------------------

  describe "argument parsing" do
    test "raises on missing config path" do
      assert_raise Mix.Error, ~r/Usage/, fn ->
        Validate.run([])
      end
    end
  end

  describe "valid config" do
    test "prints success with team and tier info" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", valid_yaml())

        output =
          capture_io(fn ->
            Validate.run([yaml_path])
          end)

        assert output =~ "[ok] Config valid: my-project"
        assert output =~ "Teams: 4"
        assert output =~ "backend"
        assert output =~ "frontend"
        assert output =~ "devops"
        assert output =~ "integration"
        assert output =~ "Tiers: 3"
        assert output =~ "Tier 0"
        assert output =~ "Tier 1"
        assert output =~ "Tier 2"
      after
        cleanup(tmp_dir)
      end
    end

    test "shows warnings when present" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_with_warnings = """
        name: "warn-test"
        teams:
          - name: solo
            lead:
              role: "Solo Dev"
            tasks:
              - summary: "Do work"
        """

        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", yaml_with_warnings)

        output =
          capture_io(fn ->
            Validate.run([yaml_path])
          end)

        assert output =~ "[ok] Config valid: warn-test"
        # Should have warnings about empty details/verify
        assert output =~ "Warnings:"
      after
        cleanup(tmp_dir)
      end
    end

    test "shows 'Warnings: none' when no warnings" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", valid_yaml())

        output =
          capture_io(fn ->
            Validate.run([yaml_path])
          end)

        assert output =~ "Warnings: none"
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "invalid config" do
    test "prints errors for unknown dependency" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "bad.yaml", invalid_yaml_unknown_dep())

        assert catch_exit(
                 capture_io(:stderr, fn ->
                   Validate.run([yaml_path])
                 end)
               ) == {:shutdown, 1}
      after
        cleanup(tmp_dir)
      end
    end

    test "prints errors for empty teams" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "empty.yaml", invalid_yaml_empty_teams())

        assert catch_exit(
                 capture_io(:stderr, fn ->
                   Validate.run([yaml_path])
                 end)
               ) == {:shutdown, 1}
      after
        cleanup(tmp_dir)
      end
    end

    test "prints errors for nonexistent file" do
      assert catch_exit(
               capture_io(:stderr, fn ->
                 Validate.run(["/nonexistent/orchestra.yaml"])
               end)
             ) == {:shutdown, 1}
    end
  end
end
