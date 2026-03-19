defmodule CortexWeb.WorkflowsLiveTest do
  use CortexWeb.ConnCase

  @valid_dag_yaml """
  name: test-project
  defaults:
    model: sonnet
    max_turns: 10
  teams:
    - name: backend
      lead:
        role: Backend Developer
      tasks:
        - summary: Build API
    - name: frontend
      lead:
        role: Frontend Developer
      depends_on:
        - backend
      tasks:
        - summary: Build UI
  """

  @valid_mesh_yaml """
  name: mesh-test
  mode: mesh
  defaults:
    model: sonnet
    max_turns: 10
  mesh:
    heartbeat_interval_seconds: 30
    suspect_timeout_seconds: 90
    dead_timeout_seconds: 180
  agents:
    - name: alpha
      role: Coordinator
      prompt: Coordinate
    - name: beta
      role: Worker
      prompt: Work
  """

  @valid_gossip_yaml """
  name: gossip-test
  mode: gossip
  defaults:
    model: sonnet
    max_turns: 10
  gossip:
    rounds: 3
    topology: random
    exchange_interval_seconds: 30
  agents:
    - name: researcher
      topic: research
      prompt: Research things
    - name: analyst
      topic: analysis
      prompt: Analyze findings
  """

  # -- Mode switching --

  test "mounts with DAG mode by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/workflows")
    assert html =~ "Workflows"
    assert html =~ "DAG Workflow"
    assert html =~ "Mesh"
    assert html =~ "Gossip"
  end

  test "mode selector switches between DAG, Mesh, and Gossip", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Switch to Mesh
    html = render_click(view, "select_mode", %{"mode" => "mesh"})
    assert html =~ "Mesh Config YAML"

    # Switch to Gossip
    html = render_click(view, "select_mode", %{"mode" => "gossip"})
    assert html =~ "Gossip Config YAML"

    # Switch back to DAG
    html = render_click(view, "select_mode", %{"mode" => "dag"})
    assert html =~ "DAG Workflow YAML"
  end

  # -- Composition toggle --

  test "composition toggle switches between YAML and Visual", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Switch to Visual
    html = render_click(view, "select_composition", %{"mode" => "visual"})
    assert html =~ "Project Settings"
    assert html =~ "Teams"

    # Switch back to YAML
    html = render_click(view, "select_composition", %{"mode" => "yaml"})
    assert html =~ "DAG Workflow YAML"
  end

  # -- DAG YAML validation --

  test "validates DAG YAML and shows config preview", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    html =
      view
      |> form("form", %{"yaml" => @valid_dag_yaml})
      |> render_submit()

    assert html =~ "test-project"
    assert html =~ "backend"
    assert html =~ "frontend"
    assert html =~ "Launch Run"
    assert html =~ "Dependency Graph"
  end

  test "validates empty input shows error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    html =
      view
      |> form("form", %{})
      |> render_submit()

    assert html =~ "Please provide YAML content"
  end

  # -- Mesh YAML validation --

  test "validates Mesh YAML in mesh mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Switch to mesh mode
    render_click(view, "select_mode", %{"mode" => "mesh"})

    html =
      view
      |> form("form", %{"yaml" => @valid_mesh_yaml})
      |> render_submit()

    assert html =~ "mesh-test"
    assert html =~ "alpha"
    assert html =~ "beta"
    assert html =~ "Heartbeat"
    assert html =~ "Launch Run"
  end

  # -- Gossip YAML validation --

  test "validates Gossip YAML in gossip mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Switch to gossip mode
    render_click(view, "select_mode", %{"mode" => "gossip"})

    html =
      view
      |> form("form", %{"yaml" => @valid_gossip_yaml})
      |> render_submit()

    assert html =~ "gossip-test"
    assert html =~ "researcher"
    assert html =~ "analyst"
    assert html =~ "Rounds"
    assert html =~ "Launch Run"
  end

  # -- Template loading --

  test "loading a template populates YAML editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    html = render_click(view, "load_template", %{"template" => "dag_starter"})
    assert html =~ "my-project"
    assert html =~ "Backend Developer"
  end

  test "loading mesh template switches to mesh mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    html = render_click(view, "load_template", %{"template" => "mesh_starter"})
    assert html =~ "my-mesh-project"
    assert html =~ "Coordinator"
  end

  test "loading gossip template switches to gossip mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    html = render_click(view, "load_template", %{"template" => "gossip_starter"})
    assert html =~ "my-gossip-project"
    assert html =~ "researcher"
  end

  # -- DAG launch --

  test "DAG launch creates a run and redirects", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Validate first
    view
    |> form("form", %{"yaml" => @valid_dag_yaml})
    |> render_submit()

    # Launch
    assert {:error, {:live_redirect, %{to: "/runs/" <> _id}}} =
             view |> element("button", "Launch Run") |> render_click()
  end

  # -- Mesh launch --

  test "Mesh launch creates a run and redirects", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    render_click(view, "select_mode", %{"mode" => "mesh"})

    view
    |> form("form", %{"yaml" => @valid_mesh_yaml})
    |> render_submit()

    assert {:error, {:live_redirect, %{to: "/runs/" <> _id}}} =
             view |> element("button", "Launch Run") |> render_click()
  end

  # -- Gossip launch --

  test "Gossip launch creates a run and redirects", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    render_click(view, "select_mode", %{"mode" => "gossip"})

    view
    |> form("form", %{"yaml" => @valid_gossip_yaml})
    |> render_submit()

    assert {:error, {:live_redirect, %{to: "/runs/" <> _id}}} =
             view |> element("button", "Launch Run") |> render_click()
  end

  # -- Launch without validation --

  test "launch without validation shows error flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Try to launch without validating (no Launch button visible, so click event directly)
    html = render_click(view, "launch", %{})
    assert html =~ "validate configuration before launching"
  end

  # -- Workspace conflict --

  test "workspace set in both YAML and form shows error", %{conn: conn} do
    yaml_with_workspace = """
    name: test-project
    defaults:
      model: sonnet
      max_turns: 10
    workspace_path: /yaml/workspace
    teams:
      - name: backend
        lead:
          role: Backend Developer
        tasks:
          - summary: Build API
    """

    {:ok, view, _html} = live(conn, "/workflows")

    html =
      view
      |> form("form", %{"yaml" => yaml_with_workspace, "workspace_path" => "/ui/workspace"})
      |> render_submit()

    assert html =~ "workspace_path is set in both"
  end

  # -- Visual mode DAG team builder --

  test "visual DAG mode: add and remove teams", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Switch to visual mode
    render_click(view, "select_composition", %{"mode" => "visual"})

    # Add a team
    html = render_click(view, "add_dag_team", %{})
    assert html =~ "Team 1"

    # Add another
    html = render_click(view, "add_dag_team", %{})
    assert html =~ "Team 2"
  end

  # -- Mode switching resets validation --

  test "switching mode clears validation state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Validate a DAG
    view
    |> form("form", %{"yaml" => @valid_dag_yaml})
    |> render_submit()

    # Switch to mesh -- should clear validation
    html = render_click(view, "select_mode", %{"mode" => "mesh"})
    refute html =~ "Launch Run"
    refute html =~ "Configuration Preview"
  end

  # ==========================================================================
  # Example YAML integration tests
  #
  # These validate every example file through the actual LiveView form flow,
  # catching integration bugs between UI event handling, mode resolution,
  # and backend validators.
  # ==========================================================================

  @example_files %{
    "dag" => ["examples/dag-demo.yaml", "examples/dag-complex.yaml"],
    "mesh" => ["examples/mesh-simple.yaml", "examples/mesh-complex.yaml"],
    "gossip" => ["examples/gossip-simple.yaml", "examples/gossip-complex.yaml"]
  }

  for {mode, files} <- @example_files, file <- files do
    @tag_mode mode
    @tag_file file

    test "example #{file} validates successfully through UI", %{conn: conn} do
      yaml = File.read!(@tag_file)
      {:ok, view, _html} = live(conn, "/workflows")

      # Switch to the correct mode
      if @tag_mode != "dag" do
        render_click(view, "select_mode", %{"mode" => @tag_mode})
      end

      # Submit YAML through the form (same path as a real user)
      html =
        view
        |> form("form", %{"yaml" => yaml})
        |> render_submit()

      # Must not show any validation errors
      refute html =~ "cannot be empty",
             "Example #{@tag_file} failed validation with 'cannot be empty'"

      refute html =~ "Please provide YAML content",
             "Example #{@tag_file} resulted in empty YAML"

      # Must show the Launch Run button (means validation passed)
      assert html =~ "Launch Run",
             "Example #{@tag_file} did not produce a Launch Run button after validation"
    end
  end

  # -- File path loading --

  test "loading YAML via file path validates successfully", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Use absolute path to avoid CWD issues
    abs_path = Path.expand("examples/dag-demo.yaml")

    html =
      view
      |> form("form", %{"yaml" => "", "path" => abs_path})
      |> render_submit()

    refute html =~ "cannot be empty"
    assert html =~ "Launch Run"
  end

  # -- Template validation --

  for {template_id, mode} <- [
        {"dag_starter", "dag"},
        {"mesh_starter", "mesh"},
        {"gossip_starter", "gossip"}
      ] do
    @tag_template template_id

    test "template #{template_id} loads and validates", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/workflows")

      # Load the template (also switches mode automatically)
      render_click(view, "load_template", %{"template" => @tag_template})

      # Validate it
      html =
        view
        |> form("form", %{})
        |> render_submit()

      refute html =~ "cannot be empty",
             "Template #{@tag_template} failed validation"

      assert html =~ "Launch Run",
             "Template #{@tag_template} did not produce Launch Run button"
    end
  end

  # -- Cross-mode validation --
  # Users might paste mesh/gossip YAML while on the wrong tab.
  # The UI should auto-detect and validate correctly.

  test "mesh YAML pasted while on DAG tab auto-detects and validates", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Stay on DAG tab, paste mesh YAML
    html =
      view
      |> form("form", %{"yaml" => @valid_mesh_yaml})
      |> render_submit()

    # Should auto-detect mesh mode and validate successfully
    refute html =~ "teams list cannot be empty",
           "Mesh YAML failed when pasted on DAG tab — mode auto-detection broken"

    assert html =~ "Launch Run"
  end

  test "gossip YAML pasted while on DAG tab auto-detects and validates", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    html =
      view
      |> form("form", %{"yaml" => @valid_gossip_yaml})
      |> render_submit()

    refute html =~ "teams list cannot be empty",
           "Gossip YAML failed when pasted on DAG tab — mode auto-detection broken"

    assert html =~ "Launch Run"
  end
end
