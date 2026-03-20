defmodule Cortex.Provider.External.IntegrationTest do
  @moduledoc """
  End-to-end integration tests for the external provider dispatch loop.

  Tests the full flow: TaskPush sends a TaskRequest to a mock agent,
  the mock agent sends back a result via route_task_result/2, and
  the waiting Provider.External.run/3 caller receives the TeamResult.
  """

  use ExUnit.Case, async: false

  alias Cortex.Gateway.Registry
  alias Cortex.Provider.External.PendingTasks
  alias Cortex.Provider.External.TaskPush

  @moduletag :integration

  defp make_agent_info(name) do
    %{
      "name" => name,
      "role" => "integration-test-agent",
      "capabilities" => ["testing"]
    }
  end

  defp start_registry do
    # Use the already-running registry from the supervision tree,
    # or start a fresh one for isolation
    name = :"integration_registry_#{System.unique_integer([:positive])}"
    {:ok, pid} = Registry.start_link(name: name)
    {name, pid}
  end

  describe "TaskPush → route_task_result round-trip" do
    test "gRPC: push task request, simulate result, deliver to caller" do
      {registry, _} = start_registry()
      test_pid = self()

      # Register a mock gRPC agent (a process that receives messages)
      mock_agent =
        spawn(fn ->
          receive do
            {:push_gateway_message, msg} ->
              send(test_pid, {:agent_received, msg})
          end

          Process.sleep(:infinity)
        end)

      agent_info = make_agent_info("grpc-integration-agent")
      {:ok, agent} = Registry.register_grpc(registry, agent_info, mock_agent)

      # Register a pending task
      task_id = Ecto.UUID.generate()
      caller_ref = make_ref()

      :ok =
        PendingTasks.register_task(
          PendingTasks,
          task_id,
          self(),
          caller_ref,
          agent.id
        )

      # Push the task request via gRPC transport
      task_request = %{
        "task_id" => task_id,
        "prompt" => "Review this code",
        "tools" => ["read_file"],
        "timeout_ms" => 30_000,
        "context" => %{"team_name" => "review-team"},
        "agent_id" => agent.id
      }

      assert {:ok, :sent} = TaskPush.push(:grpc, mock_agent, task_request)

      # Verify the mock agent received the GatewayMessage
      assert_receive {:agent_received, gateway_msg}, 1000
      assert %Cortex.Gateway.Proto.GatewayMessage{msg: {:task_request, proto_req}} = gateway_msg
      assert proto_req.task_id == task_id
      assert proto_req.prompt == "Review this code"

      # Simulate the sidecar sending back a task result
      result = %{
        "status" => "completed",
        "result_text" => "No issues found",
        "duration_ms" => 2500,
        "input_tokens" => 200,
        "output_tokens" => 75
      }

      assert :ok = Registry.route_task_result(task_id, result)

      # Verify the caller received the result
      assert_receive {:task_result, ^caller_ref, ^result}, 1000
    end

    test "websocket: push task request, simulate result, deliver to caller" do
      {registry, _} = start_registry()
      test_pid = self()

      # Register a mock WebSocket agent
      mock_channel =
        spawn(fn ->
          receive do
            {:push_to_agent, event, payload} ->
              send(test_pid, {:channel_received, event, payload})
          end

          Process.sleep(:infinity)
        end)

      agent_info = make_agent_info("ws-integration-agent")
      {:ok, agent} = Registry.register(registry, agent_info, mock_channel)

      # Register a pending task
      task_id = Ecto.UUID.generate()
      caller_ref = make_ref()

      :ok =
        PendingTasks.register_task(
          PendingTasks,
          task_id,
          self(),
          caller_ref,
          agent.id
        )

      # Push the task request via WebSocket transport
      task_request = %{
        "task_id" => task_id,
        "prompt" => "Analyze performance",
        "tools" => [],
        "timeout_ms" => 60_000,
        "context" => %{},
        "agent_id" => agent.id
      }

      assert {:ok, :sent} = TaskPush.push(:websocket, mock_channel, task_request)

      # Verify the mock channel received the push
      assert_receive {:channel_received, "task_request", payload}, 1000
      assert payload["task_id"] == task_id
      assert payload["prompt"] == "Analyze performance"

      # Simulate the result coming back
      result = %{
        "status" => "completed",
        "result_text" => "Bottleneck found in query layer",
        "duration_ms" => 5000,
        "input_tokens" => 300,
        "output_tokens" => 150
      }

      assert :ok = Registry.route_task_result(task_id, result)
      assert_receive {:task_result, ^caller_ref, ^result}, 1000
    end

    test "unknown task_id returns error from route_task_result" do
      unknown_id = Ecto.UUID.generate()

      result = %{
        "status" => "completed",
        "result_text" => "orphaned result",
        "duration_ms" => 100
      }

      assert {:error, :unknown_task} = Registry.route_task_result(unknown_id, result)
    end

    test "push to dead agent transport returns :transport_down" do
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      task_request = %{
        "task_id" => Ecto.UUID.generate(),
        "prompt" => "test",
        "tools" => [],
        "timeout_ms" => 1000,
        "context" => %{},
        "agent_id" => "dead-agent"
      }

      assert {:error, :transport_down} = TaskPush.push(:grpc, dead_pid, task_request)
      assert {:error, :transport_down} = TaskPush.push(:websocket, dead_pid, task_request)
    end
  end
end
