defmodule Cortex.Orchestration.Runner.ExecutorExternalTest do
  use ExUnit.Case, async: false

  alias Cortex.Agent.ExternalAgent
  alias Cortex.Agent.ExternalSupervisor
  alias Cortex.Gateway.Registry, as: GatewayRegistry
  alias Cortex.Orchestration.Runner
  alias Cortex.Orchestration.Workspace
  alias Cortex.Provider.External.PendingTasks

  @moduletag :orchestration

  # -- Helpers --

  defp create_tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cortex_executor_ext_test_#{:erlang.unique_integer([:positive])}"
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
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Working..."}]}}'
    echo '{"type":"result","subtype":"success","result":"All tasks completed","cost_usd":0.25,"num_turns":3,"duration_ms":15000}'
    """
  end

  defp register_mock_sidecar(team_name) do
    # Spawn a long-lived process to act as the gRPC stream transport pid.
    # TaskPush.push(:grpc, pid, request) just does send(pid, msg), so
    # this process only needs to be alive to receive messages.
    transport_pid = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, agent} =
      GatewayRegistry.register_grpc(
        %{
          "name" => team_name,
          "role" => "worker",
          "capabilities" => ["general"]
        },
        transport_pid
      )

    {agent, transport_pid}
  end

  defp cleanup_sidecar(team_name, transport_pid) do
    # Stop ExternalAgent if running
    case ExternalSupervisor.find_agent(team_name) do
      {:ok, pid} ->
        try do
          ExternalAgent.stop(pid)
        catch
          _, _ -> :ok
        end

      :not_found ->
        :ok
    end

    # Kill the transport pid — Gateway.Registry auto-unregisters
    # the agent when the transport pid goes down.
    if Process.alive?(transport_pid), do: Process.exit(transport_pid, :kill)

    # Give the registry a moment to process the DOWN message
    Process.sleep(50)
  end

  defp external_yaml(team_name) do
    """
    name: "external-test"
    defaults:
      model: sonnet
      max_turns: 10
      permission_mode: acceptEdits
      timeout_minutes: 5
      provider: external
    teams:
      - name: #{team_name}
        lead:
          role: "Worker"
        tasks:
          - summary: "Do external work"
        depends_on: []
    """
  end

  defp cli_yaml do
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
        depends_on: []
    """
  end

  # Spawns a background process that polls PendingTasks and resolves
  # any pending tasks with a success result. This simulates the sidecar
  # returning a TaskResult via route_task_result.
  defp start_mock_sidecar do
    test_pid = self()
    spawn_link(fn -> mock_sidecar_loop(test_pid) end)
  end

  defp mock_sidecar_loop(test_pid) do
    Process.sleep(20)

    tasks =
      try do
        PendingTasks.list_pending(PendingTasks)
      rescue
        _ -> []
      end

    case tasks do
      [] ->
        mock_sidecar_loop(test_pid)

      entries when is_list(entries) ->
        Enum.each(entries, fn entry ->
          task_id = entry.task_id

          result = %{
            "task_id" => task_id,
            "status" => "completed",
            "result_text" => "External task completed",
            "duration_ms" => 200,
            "input_tokens" => 100,
            "output_tokens" => 50
          }

          PendingTasks.resolve_task(PendingTasks, task_id, result)
          send(test_pid, {:task_resolved, task_id})
        end)
    end
  end

  # -- Tests: External provider dispatch --

  describe "executor with provider: external" do
    test "routes through ExternalAgent and completes successfully" do
      team_name = "ext-success-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()

      {_agent, transport_pid} = register_mock_sidecar(team_name)
      _mock = start_mock_sidecar()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))

        assert {:ok, summary} = Runner.run(yaml_path, workspace_path: tmp_dir)

        assert summary.status == :complete
        assert summary.project == "external-test"
        assert map_size(summary.teams) == 1
        assert summary.teams[team_name].status == "done"
      after
        cleanup_sidecar(team_name, transport_pid)
        cleanup(tmp_dir)
      end
    end

    test "returns error outcome when sidecar is not registered" do
      team_name = "no-sidecar-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))

        # ExternalAgent.start_link will fail because no agent is registered,
        # producing {:error, :agent_not_found} from ensure_external_agent.
        # The executor should return a clean tier failure, not a crash.
        result = Runner.run(yaml_path, workspace_path: tmp_dir, continue_on_error: false)

        assert {:error, {:tier_failed, 0, [^team_name]}} = result
      after
        cleanup(tmp_dir)
      end
    end
  end

  # -- Regression test: CLI path unchanged --

  describe "executor with provider: cli (regression)" do
    test "CLI path still works after external dispatch changes" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", cli_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson())

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        assert summary.status == :complete
        assert summary.project == "cli-test"
        assert summary.teams["backend"].status == "done"
        assert summary.total_cost > 0
      after
        cleanup(tmp_dir)
      end
    end
  end

  # -- Integration test --

  describe "end-to-end external agent flow" do
    @describetag :integration

    test "full DAG run with mock sidecar" do
      team_name = "ext-e2e-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()

      {_agent, transport_pid} = register_mock_sidecar(team_name)
      _mock = start_mock_sidecar()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))

        assert {:ok, summary} = Runner.run(yaml_path, workspace_path: tmp_dir)

        assert summary.status == :complete

        # Verify workspace state
        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)
        assert state.teams[team_name].status == "done"

        # Verify ExternalAgent is still alive (persists for potential reuse)
        assert {:ok, pid} = ExternalSupervisor.find_agent(team_name)
        assert Process.alive?(pid)
      after
        cleanup_sidecar(team_name, transport_pid)
        cleanup(tmp_dir)
      end
    end

    test "ExternalAgent persists after run for reuse" do
      team_name = "ext-persist-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()

      {_agent, transport_pid} = register_mock_sidecar(team_name)
      _mock = start_mock_sidecar()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))

        assert {:ok, _summary} = Runner.run(yaml_path, workspace_path: tmp_dir)

        # The ExternalAgent should still be running after the run completes
        assert {:ok, pid} = ExternalSupervisor.find_agent(team_name)
        assert Process.alive?(pid)

        # And it should be in healthy state
        {:ok, state} = ExternalAgent.get_state(pid)
        assert state.status == :healthy
        assert state.name == team_name
      after
        cleanup_sidecar(team_name, transport_pid)
        cleanup(tmp_dir)
      end
    end
  end
end
