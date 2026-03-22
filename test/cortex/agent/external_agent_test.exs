defmodule Cortex.Agent.ExternalAgentTest do
  use ExUnit.Case, async: false

  alias Cortex.Agent.ExternalAgent
  alias Cortex.Gateway.Registry, as: GatewayRegistry
  alias Cortex.Provider.External.PendingTasks

  @agent_name "test-external-agent"

  setup do
    # Cortex.PubSub is already started by the application supervision tree.

    # Start Gateway.Registry with a unique name per test
    registry_name = :"gateway_registry_#{System.unique_integer([:positive])}"
    start_supervised!({GatewayRegistry, name: registry_name})

    # Start PendingTasks with a unique name per test
    pending_name = :"pending_tasks_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Cortex.Provider.External.PendingTasks, name: pending_name, table_name: pending_name}
    )

    %{registry: registry_name, pending_tasks: pending_name}
  end

  defp register_mock_agent(registry, name) do
    # Spawn a long-lived process to act as the transport pid
    transport_pid = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, agent} =
      GatewayRegistry.register_grpc(
        registry,
        %{
          "name" => name,
          "role" => "worker",
          "capabilities" => ["general"]
        },
        transport_pid
      )

    {agent, transport_pid}
  end

  defp start_external_agent(ctx, opts \\ []) do
    name = Keyword.get(opts, :name, @agent_name)

    agent_opts =
      [
        name: name,
        registry: ctx.registry,
        timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
        pending_tasks: ctx.pending_tasks
      ]
      |> maybe_add_push_fn(Keyword.get(opts, :push_fn))

    start_supervised!({ExternalAgent, agent_opts}, id: :"external_agent_#{name}")
  end

  defp maybe_add_push_fn(opts, nil), do: opts
  defp maybe_add_push_fn(opts, push_fn), do: Keyword.put(opts, :push_fn, push_fn)

  # -- Init Tests --

  describe "start_link/1" do
    test "succeeds when sidecar is registered", ctx do
      {_agent, _pid} = register_mock_agent(ctx.registry, @agent_name)
      pid = start_external_agent(ctx)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "returns error when no matching agent in registry", ctx do
      Process.flag(:trap_exit, true)

      result =
        ExternalAgent.start_link(
          name: "nonexistent-agent",
          registry: ctx.registry,
          pending_tasks: ctx.pending_tasks
        )

      assert {:error, :agent_not_found} = result
    end

    test "returns error when registry is not available", ctx do
      Process.flag(:trap_exit, true)

      result =
        ExternalAgent.start_link(
          name: @agent_name,
          registry: :nonexistent_registry,
          pending_tasks: ctx.pending_tasks
        )

      assert {:error, :registry_not_available} = result
    end
  end

  # -- get_state Tests --

  describe "get_state/1" do
    test "returns correct agent info", ctx do
      {agent, _pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      {:ok, state} = ExternalAgent.get_state(ea_pid)

      assert state.name == @agent_name
      assert state.agent_id == agent.id
      assert state.status == :healthy
      assert state.agent_info.name == @agent_name
    end
  end

  # -- run/3 Tests --

  describe "run/3" do
    test "delegates to Provider.External and returns result", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)

      # Create a push_fn that simulates a sidecar: captures the request,
      # and resolves the pending task with a success result
      test_pid = self()
      pending = ctx.pending_tasks

      push_fn = fn _transport, _pid, task_request ->
        send(test_pid, {:push_called, task_request})

        # Simulate sidecar returning a result after a short delay
        spawn(fn ->
          Process.sleep(10)
          task_id = task_request["task_id"]

          result = %{
            "task_id" => task_id,
            "status" => "completed",
            "result_text" => "Task done!",
            "duration_ms" => 100,
            "input_tokens" => 50,
            "output_tokens" => 25
          }

          PendingTasks.resolve_task(pending, task_id, result)
        end)

        {:ok, :sent}
      end

      ea_pid = start_external_agent(ctx, push_fn: push_fn)
      {:ok, team_result} = ExternalAgent.run(ea_pid, "Build the API")

      assert team_result.team == @agent_name
      assert team_result.status == :success
      assert team_result.result == "Task done!"

      # Verify push was called
      assert_received {:push_called, request}
      assert request["prompt"] == "Build the API"
    end

    test "returns {:error, :agent_unhealthy} on unhealthy agent", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      # Simulate sidecar disconnect by broadcasting agent_unregistered
      Cortex.Events.broadcast(:agent_unregistered, %{
        agent_id: agent.id,
        name: @agent_name,
        reason: :channel_down
      })

      # Give PubSub a moment to deliver
      Process.sleep(50)

      result = ExternalAgent.run(ea_pid, "Should fail")
      assert {:error, :agent_unhealthy} = result
    end

    test "returns {:error, :timeout} when sidecar doesn't respond", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)

      # Push function that succeeds but never resolves the task
      push_fn = fn _transport, _pid, _task_request ->
        {:ok, :sent}
      end

      ea_pid = start_external_agent(ctx, push_fn: push_fn, timeout_ms: 100)
      result = ExternalAgent.run(ea_pid, "Should timeout", timeout_ms: 100)
      assert {:error, :timeout} = result
    end
  end

  # -- PubSub Event Tests --

  describe "PubSub event handling" do
    test "agent_unregistered for matching agent_id transitions to unhealthy", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :healthy

      Cortex.Events.broadcast(:agent_unregistered, %{
        agent_id: agent.id,
        name: @agent_name,
        reason: :channel_down
      })

      Process.sleep(50)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :unhealthy
    end

    test "agent_unregistered for non-matching agent_id is ignored", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      Cortex.Events.broadcast(:agent_unregistered, %{
        agent_id: "some-other-id",
        name: "other-agent",
        reason: :channel_down
      })

      Process.sleep(50)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :healthy
    end

    test "agent_registered with matching name restores healthy and updates agent info", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      # Mark unhealthy via disconnect
      Cortex.Events.broadcast(:agent_unregistered, %{
        agent_id: agent.id,
        name: @agent_name,
        reason: :channel_down
      })

      Process.sleep(50)
      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :unhealthy

      # Register a new agent with the same name (simulating reconnect)
      new_transport_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, new_agent} =
        GatewayRegistry.register_grpc(
          ctx.registry,
          %{
            "name" => @agent_name,
            "role" => "worker",
            "capabilities" => ["general"]
          },
          new_transport_pid
        )

      # The agent_registered event was broadcast by Gateway.Registry.register_grpc
      Process.sleep(50)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :healthy
      assert state.agent_id == new_agent.id
    end

    test "agent_registered with non-matching name is ignored", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      Cortex.Events.broadcast(:agent_registered, %{
        agent_id: "some-new-id",
        name: "different-agent",
        role: "worker",
        capabilities: ["general"]
      })

      Process.sleep(50)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.agent_id == agent.id
      assert state.status == :healthy
    end

    test "agent_status_changed updates cached agent_info", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      Cortex.Events.broadcast(:agent_status_changed, %{
        agent_id: agent.id,
        old_status: :idle,
        new_status: :working
      })

      Process.sleep(50)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.agent_info.status == :working
    end
  end

  # -- stop/1 Tests --

  describe "stop/1" do
    test "gracefully stops the GenServer", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      assert Process.alive?(ea_pid)
      :ok = ExternalAgent.stop(ea_pid)
      refute Process.alive?(ea_pid)
    end
  end
end
