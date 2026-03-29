defmodule Cortex.Orchestration.GateTest do
  use CortexWeb.ConnCase, async: false

  alias Cortex.Orchestration.Runner
  alias Cortex.Orchestration.Workspace
  alias Cortex.Store

  import Cortex.Test.Sense

  @moduletag :integration

  # -- Helpers -----------------------------------------------------------------

  defp create_tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cortex_gate_test_#{:erlang.unique_integer([:positive])}"
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

  defp success_ndjson(result_text) do
    """
    echo '{"type":"system","subtype":"init","session_id":"sess-001"}'
    echo '{"type":"result","subtype":"success","result":"#{result_text}","cost_usd":0.10,"num_turns":2,"duration_ms":5000}'
    """
  end

  # A mock script that checks if the prompt (passed via -p flag) contains
  # "REST" from gate notes. Outputs different results accordingly.
  defp pivot_aware_mock do
    """
    # Capture all args as the full prompt
    ALL_ARGS="$*"

    if echo "$ALL_ARGS" | grep -qi "pivot to REST"; then
      RESULT="Pivoted: Built REST API with JSON endpoints and resource routing"
    else
      RESULT="Original: Built GraphQL API with schema-first design"
    fi

    echo '{"type":"system","subtype":"init","session_id":"sess-002"}'
    echo "{\\\"type\\\":\\\"result\\\",\\\"subtype\\\":\\\"success\\\",\\\"result\\\":\\\"$RESULT\\\",\\\"cost_usd\\\":0.15,\\\"num_turns\\\":3,\\\"duration_ms\\\":8000}"
    """
  end

  defp gated_two_tier_yaml do
    """
    name: "gate-test-project"
    defaults:
      model: haiku
      max_turns: 5
      permission_mode: bypassPermissions
      timeout_minutes: 5
    gates:
      after_tier: [0]
    teams:
      - name: design
        lead:
          role: "API Designer"
        tasks:
          - summary: "Design the API"
        depends_on: []
      - name: implementation
        lead:
          role: "API Developer"
        tasks:
          - summary: "Implement the API"
        depends_on:
          - design
    """
  end

  defp every_tier_gated_yaml do
    """
    name: "every-gate-project"
    defaults:
      model: haiku
      max_turns: 5
      permission_mode: bypassPermissions
      timeout_minutes: 5
    gates:
      every_tier: true
    teams:
      - name: alpha
        lead:
          role: "Alpha Lead"
        tasks:
          - summary: "Alpha work"
        depends_on: []
      - name: beta
        lead:
          role: "Beta Lead"
        tasks:
          - summary: "Beta work"
        depends_on:
          - alpha
    """
  end

  # -- Tests -------------------------------------------------------------------

  describe "gated workflow: run pauses at gate" do
    test "run halts after tier 0 with status gated" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", gated_two_tier_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson("Design complete"))

        {:ok, run} =
          Store.create_run(%{
            name: "gate-test-project",
            status: "pending",
            team_count: 2
          })

        assert {:ok, result} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir,
                   run_id: run.id
                 )

        assert result.status == :gated
        assert result.gated_at_tier == 0

        # Verify DB state
        db_run = Store.get_run(run.id)
        assert db_run.status == "gated"
        assert db_run.gated_at_tier == 0

        # Verify gate decision was created
        decisions = Store.get_gate_decisions(run.id)
        assert length(decisions) == 1
        [decision] = decisions
        assert decision.tier == 0
        assert decision.decision == "pending"
        assert is_nil(decision.decided_by)

        # Verify tier 0 team completed, tier 1 team still pending
        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)
        assert state.teams["design"].status == "done"
        assert state.teams["implementation"].status == "pending"
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "gated workflow: approve and continue" do
    test "approve_gate resumes run and completes remaining tiers" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", gated_two_tier_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson("Done"))

        {:ok, run} =
          Store.create_run(%{
            name: "gate-test-project",
            status: "pending",
            team_count: 2,
            config_yaml: gated_two_tier_yaml(),
            workspace_path: tmp_dir
          })

        # Run tier 0 — should gate
        assert {:ok, %{status: :gated}} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir,
                   run_id: run.id
                 )

        # Approve the gate
        assert {:ok, _} =
                 Runner.approve_gate(run.id,
                   decided_by: "alice",
                   notes: "Looks good, proceed",
                   command: mock,
                   continue_on_error: true
                 )

        # Verify run completed
        db_run = Store.get_run(run.id)
        assert db_run.status in ["completed", "running"]

        # Verify gate decision was approved
        decisions = Store.get_gate_decisions(run.id)
        approved = Enum.find(decisions, &(&1.decision == "approved"))
        assert approved != nil
        assert approved.decided_by == "alice"
        assert approved.notes == "Looks good, proceed"
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "gated workflow: reject gate" do
    test "reject_gate cancels the run" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", gated_two_tier_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson("Done"))

        {:ok, run} =
          Store.create_run(%{
            name: "gate-test-project",
            status: "pending",
            team_count: 2,
            config_yaml: gated_two_tier_yaml(),
            workspace_path: tmp_dir
          })

        assert {:ok, %{status: :gated}} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir,
                   run_id: run.id
                 )

        assert {:ok, :rejected} =
                 Runner.reject_gate(run.id,
                   decided_by: "bob",
                   notes: "Output quality too low"
                 )

        db_run = Store.get_run(run.id)
        assert db_run.status == "cancelled"
        assert is_nil(db_run.gated_at_tier)

        decisions = Store.get_gate_decisions(run.id)
        rejected = Enum.find(decisions, &(&1.decision == "rejected"))
        assert rejected != nil
        assert rejected.decided_by == "bob"
        assert rejected.notes == "Output quality too low"
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "gated workflow: idempotent approve" do
    test "approve_gate on non-gated run returns noop" do
      {:ok, run} =
        Store.create_run(%{
          name: "noop-test",
          status: "completed",
          team_count: 1
        })

      assert {:ok, :noop} = Runner.approve_gate(run.id)
    end

    test "reject_gate on non-gated run returns noop" do
      {:ok, run} =
        Store.create_run(%{
          name: "noop-test",
          status: "completed",
          team_count: 1
        })

      assert {:ok, :noop} = Runner.reject_gate(run.id)
    end
  end

  describe "gated workflow: cancel_run" do
    test "cancel_run on completed run returns noop" do
      {:ok, run} =
        Store.create_run(%{
          name: "cancel-noop",
          status: "completed",
          team_count: 1
        })

      assert {:ok, :noop} = Runner.cancel_run(run.id)
    end

    test "cancel_run on gated run cancels it" do
      {:ok, run} =
        Store.create_run(%{
          name: "cancel-gated",
          status: "gated",
          team_count: 1,
          gated_at_tier: 0
        })

      # Create a pending gate decision so reject_gate can find it
      Store.create_gate_decision(%{run_id: run.id, tier: 0, decision: "pending"})

      assert {:ok, :rejected} = Runner.cancel_run(run.id)

      db_run = Store.get_run(run.id)
      assert db_run.status == "cancelled"
    end
  end

  describe "gated workflow: every_tier gate" do
    test "gates fire after every tier" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", every_tier_gated_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson("Done"))

        {:ok, run} =
          Store.create_run(%{
            name: "every-gate-project",
            status: "pending",
            team_count: 2,
            config_yaml: every_tier_gated_yaml(),
            workspace_path: tmp_dir
          })

        # Tier 0 should gate
        assert {:ok, %{status: :gated, gated_at_tier: 0}} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir,
                   run_id: run.id
                 )

        # Approve tier 0 — should gate again at tier 1
        assert {:ok, result} =
                 Runner.approve_gate(run.id,
                   decided_by: "alice",
                   command: mock
                 )

        # After approve+continue, the continued run should gate at tier 1
        assert result.status == :gated
        assert result.gated_at_tier == 1
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "gated workflow with Sense: gate notes pivot agent direction" do
    test "gate notes inject into prompt and change agent output" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", gated_two_tier_yaml())

        # Tier 0 mock: fixed output
        tier0_mock =
          write_mock_script(
            tmp_dir,
            "mock_tier0.sh",
            success_ndjson("Designed GraphQL API with schema-first approach")
          )

        # Tier 1 mock: checks prompt for gate notes, pivots output
        tier1_mock = write_mock_script(tmp_dir, "mock_tier1.sh", pivot_aware_mock())

        {:ok, run} =
          Store.create_run(%{
            name: "gate-test-project",
            status: "pending",
            team_count: 2,
            config_yaml: gated_two_tier_yaml(),
            workspace_path: tmp_dir
          })

        # Run tier 0 with tier0 mock — should gate
        assert {:ok, %{status: :gated}} =
                 Runner.run(yaml_path,
                   command: tier0_mock,
                   workspace_path: tmp_dir,
                   run_id: run.id
                 )

        # Verify tier 0 completed with GraphQL output
        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)
        assert_sense(state.teams["design"].result_summary, "graphql")

        # Approve with pivot notes — this completely changes direction
        assert {:ok, _} =
                 Runner.approve_gate(run.id,
                   decided_by: "alice",
                   notes: "Pivot to REST API instead of GraphQL. Use resource-based routing.",
                   command: tier1_mock,
                   continue_on_error: true
                 )

        # Verify the implementation team got the gate notes and pivoted
        team_run = Store.get_team_run(run.id, "implementation")
        assert team_run != nil

        # The prompt should contain the gate notes
        assert_sense(team_run.prompt, "human review notes")
        assert_sense(team_run.prompt, "pivot to rest")

        # The result should reflect the pivot
        assert_sense(team_run.result_summary, "rest")
        refute_sense(team_run.result_summary, "graphql")

        # Gate decision history is complete
        decisions = Store.get_gate_decisions(run.id)
        assert length(decisions) == 1
        [d] = decisions
        assert d.decision == "approved"
        assert d.decided_by == "alice"
        assert_sense(d.notes, "pivot to rest")
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "PubSub gate events" do
    test "broadcasts gate_pending and gate_approved events" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", gated_two_tier_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson("Done"))

        {:ok, run} =
          Store.create_run(%{
            name: "gate-test-project",
            status: "pending",
            team_count: 2,
            config_yaml: gated_two_tier_yaml(),
            workspace_path: tmp_dir
          })

        Cortex.Events.subscribe()

        assert {:ok, %{status: :gated}} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir,
                   run_id: run.id
                 )

        assert_received %{type: :gate_pending, payload: %{run_id: _, tier: 0}}

        assert {:ok, _} =
                 Runner.approve_gate(run.id,
                   decided_by: "alice",
                   command: mock
                 )

        assert_received %{type: :gate_approved, payload: %{run_id: _, tier: 0}}
      after
        cleanup(tmp_dir)
      end
    end
  end
end
