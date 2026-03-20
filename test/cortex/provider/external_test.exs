defmodule Cortex.Provider.ExternalTest do
  use ExUnit.Case, async: true

  alias Cortex.Gateway.Registry
  alias Cortex.Orchestration.TeamResult
  alias Cortex.Provider.External
  alias Cortex.Provider.External.PendingTasks

  # -- Test Helpers --

  defp start_registry!(ctx) do
    name = :"registry_#{ctx.test}"
    {:ok, pid} = Registry.start_link(name: name)
    {pid, name}
  end

  defp start_pending_tasks!(ctx) do
    table = :"pt_table_#{ctx.test}"
    name = :"pt_#{ctx.test}"
    {:ok, pid} = PendingTasks.start_link(name: name, table_name: table)
    {pid, name}
  end

  defp register_agent!(registry, name) do
    agent_info = %{
      "name" => name,
      "role" => "worker",
      "capabilities" => ["general"]
    }

    # Spawn a fake channel pid to register the agent with
    channel_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, agent} = Registry.register(registry, agent_info, channel_pid)
    {agent, channel_pid}
  end

  defp build_handle(registry, pending_tasks, push_fn) do
    %{
      registry: registry,
      timeout_ms: 5_000,
      pending_tasks: pending_tasks,
      push_fn: push_fn
    }
  end

  defp make_push_fn(test_pid) do
    fn _transport, _pid, _task_request ->
      send(test_pid, :push_called)
      {:ok, :sent}
    end
  end

  defp make_failing_push_fn do
    fn _transport, _pid, _task_request ->
      {:error, :transport_down}
    end
  end

  # Resolve from a separate process after a delay
  defp async_resolve(pending_tasks, result, delay_ms) do
    spawn(fn ->
      Process.sleep(delay_ms)
      # We need to find the task_id - use list_pending
      pending = PendingTasks.list_pending(pending_tasks)

      case pending do
        [%{task_id: task_id} | _] ->
          PendingTasks.resolve_task(pending_tasks, task_id, result)

        [] ->
          :no_pending_tasks
      end
    end)
  end

  # -- Tests --

  describe "start/1" do
    test "with running registry returns handle", ctx do
      {_pid, registry_name} = start_registry!(ctx)

      assert {:ok, handle} = External.start(registry: registry_name)
      assert handle.registry == registry_name
      assert handle.timeout_ms == 1_800_000
    end

    test "returns {:error, :registry_not_available} when registry not running" do
      assert {:error, :registry_not_available} =
               External.start(registry: :nonexistent_registry_for_test)
    end

    test "accepts custom timeout_ms", ctx do
      {_pid, registry_name} = start_registry!(ctx)

      assert {:ok, handle} = External.start(registry: registry_name, timeout_ms: 5_000)
      assert handle.timeout_ms == 5_000
    end

    test "accepts map config", ctx do
      {_pid, registry_name} = start_registry!(ctx)

      assert {:ok, handle} = External.start(%{registry: registry_name})
      assert handle.registry == registry_name
    end
  end

  describe "stop/1" do
    test "returns :ok" do
      assert :ok = External.stop(%{})
    end
  end

  describe "run/3" do
    test "agent not found returns {:error, :agent_not_found}", ctx do
      {_pid, registry_name} = start_registry!(ctx)
      {_pid, pt_name} = start_pending_tasks!(ctx)

      handle = build_handle(registry_name, pt_name, make_push_fn(self()))

      assert {:error, :agent_not_found} =
               External.run(handle, "do something", team_name: "nonexistent")
    end

    test "dispatches task and returns TeamResult on successful result", ctx do
      {_pid, registry_name} = start_registry!(ctx)
      {_pid, pt_name} = start_pending_tasks!(ctx)

      {_agent, _channel} = register_agent!(registry_name, "backend")

      test_pid = self()

      push_fn = fn _transport, _pid, _task_request ->
        send(test_pid, :push_called)
        {:ok, :sent}
      end

      handle = build_handle(registry_name, pt_name, push_fn)

      # Resolve the task asynchronously after a short delay
      result = %{
        "status" => "completed",
        "result_text" => "Task completed successfully",
        "duration_ms" => 1500,
        "input_tokens" => 100,
        "output_tokens" => 200
      }

      async_resolve(pt_name, result, 100)

      assert {:ok, %TeamResult{} = team_result} =
               External.run(handle, "build the API", team_name: "backend")

      assert team_result.team == "backend"
      assert team_result.status == :success
      assert team_result.result == "Task completed successfully"
      assert team_result.duration_ms == 1500
      assert team_result.input_tokens == 100
      assert team_result.output_tokens == 200
      assert team_result.cost_usd == nil
      assert team_result.session_id == nil

      assert_received :push_called
    end

    test "returns {:error, :timeout} when no result arrives", ctx do
      {_pid, registry_name} = start_registry!(ctx)
      {_pid, pt_name} = start_pending_tasks!(ctx)

      {_agent, _channel} = register_agent!(registry_name, "slow-agent")

      handle = %{
        registry: registry_name,
        timeout_ms: 100,
        pending_tasks: pt_name,
        push_fn: make_push_fn(self())
      }

      assert {:error, :timeout} =
               External.run(handle, "slow task", team_name: "slow-agent")

      # Pending task should have been cleaned up
      assert PendingTasks.list_pending(pt_name) == []
    end

    test "returns {:error, :push_failed} when push fails", ctx do
      {_pid, registry_name} = start_registry!(ctx)
      {_pid, pt_name} = start_pending_tasks!(ctx)

      {_agent, _channel} = register_agent!(registry_name, "agent-1")

      handle = build_handle(registry_name, pt_name, make_failing_push_fn())

      assert {:error, :push_failed} =
               External.run(handle, "do work", team_name: "agent-1")

      # Pending task should have been cleaned up
      assert PendingTasks.list_pending(pt_name) == []
    end

    test "emits telemetry events on dispatch and completion", ctx do
      {_pid, registry_name} = start_registry!(ctx)
      {_pid, pt_name} = start_pending_tasks!(ctx)

      {_agent, _channel} = register_agent!(registry_name, "telem-agent")

      # Attach telemetry handlers
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-dispatch-#{inspect(ref)}",
        [:cortex, :gateway, :task, :dispatched],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_dispatched, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-completed-#{inspect(ref)}",
        [:cortex, :gateway, :task, :completed],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_completed, metadata})
        end,
        nil
      )

      handle = build_handle(registry_name, pt_name, make_push_fn(self()))

      result = %{
        "status" => "completed",
        "result_text" => "done",
        "duration_ms" => 500,
        "input_tokens" => 50,
        "output_tokens" => 100
      }

      async_resolve(pt_name, result, 100)

      assert {:ok, _} = External.run(handle, "test", team_name: "telem-agent")

      assert_receive {:telemetry_dispatched, dispatch_meta}
      assert is_binary(dispatch_meta.task_id)
      assert is_binary(dispatch_meta.agent_id)

      assert_receive {:telemetry_completed, complete_meta}
      assert complete_meta.status == :success

      # Clean up handlers
      :telemetry.detach("test-dispatch-#{inspect(ref)}")
      :telemetry.detach("test-completed-#{inspect(ref)}")
    end

    test "respects per-run timeout_ms override", ctx do
      {_pid, registry_name} = start_registry!(ctx)
      {_pid, pt_name} = start_pending_tasks!(ctx)

      {_agent, _channel} = register_agent!(registry_name, "timeout-agent")

      handle = %{
        registry: registry_name,
        timeout_ms: 60_000,
        pending_tasks: pt_name,
        push_fn: make_push_fn(self())
      }

      # Per-run override to a very short timeout
      assert {:error, :timeout} =
               External.run(handle, "task", team_name: "timeout-agent", timeout_ms: 100)
    end
  end

  describe "convert_to_team_result/2" do
    test "maps completed status to :success" do
      result = %{"status" => "completed", "result_text" => "done"}
      team_result = External.convert_to_team_result(result, "team-a")

      assert team_result.status == :success
      assert team_result.team == "team-a"
      assert team_result.result == "done"
    end

    test "maps failed status to :error" do
      result = %{"status" => "failed", "result_text" => "oops"}
      team_result = External.convert_to_team_result(result, "team-a")

      assert team_result.status == :error
    end

    test "maps cancelled status to :error" do
      result = %{"status" => "cancelled"}
      team_result = External.convert_to_team_result(result, "team-a")

      assert team_result.status == :error
    end

    test "maps unknown status to :error" do
      result = %{"status" => "something_else"}
      team_result = External.convert_to_team_result(result, "team-a")

      assert team_result.status == :error
    end

    test "handles missing fields gracefully" do
      result = %{}
      team_result = External.convert_to_team_result(result, "team-a")

      assert team_result.team == "team-a"
      # Missing status defaults to "completed" -> :success
      assert team_result.status == :success
      assert team_result.result == nil
      assert team_result.duration_ms == nil
      assert team_result.input_tokens == nil
      assert team_result.output_tokens == nil
      assert team_result.cost_usd == nil
      assert team_result.session_id == nil
      assert team_result.cache_read_tokens == nil
      assert team_result.cache_creation_tokens == nil
      assert team_result.num_turns == nil
    end

    test "maps all fields from a complete result" do
      result = %{
        "status" => "completed",
        "result_text" => "All done",
        "duration_ms" => 2500,
        "input_tokens" => 1000,
        "output_tokens" => 500
      }

      team_result = External.convert_to_team_result(result, "backend")

      assert %TeamResult{
               team: "backend",
               status: :success,
               result: "All done",
               duration_ms: 2500,
               input_tokens: 1000,
               output_tokens: 500,
               cost_usd: nil,
               session_id: nil,
               cache_read_tokens: nil,
               cache_creation_tokens: nil,
               num_turns: nil
             } = team_result
    end
  end
end
