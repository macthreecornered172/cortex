defmodule Cortex.Agent.IntegrationTest do
  use ExUnit.Case, async: false

  alias Cortex.Agent.Config
  alias Cortex.Agent.Server
  alias Cortex.Events

  # Integration tests verify PubSub event broadcasting end-to-end.
  # These are not async because they subscribe to a shared PubSub topic
  # and need to receive events without interference from other tests.

  setup do
    # Subscribe this test process to all Cortex events
    :ok = Events.subscribe()

    config = Config.new!(%{name: "integration-agent", role: "tester"})
    {:ok, pid} = Server.start_link(config)
    {:ok, state} = GenServer.call(pid, :get_state)
    agent_id = state.id

    on_exit(fn ->
      if Process.alive?(pid), do: Server.stop(agent_id)
    end)

    %{config: config, pid: pid, agent_id: agent_id}
  end

  describe "agent_started event" do
    test "broadcasts :agent_started on start", %{agent_id: agent_id} do
      assert_receive %{
                       type: :agent_started,
                       payload: %{agent_id: ^agent_id, name: "integration-agent", role: "tester"},
                       timestamp: %DateTime{}
                     },
                     1000
    end
  end

  describe "agent_status_changed event" do
    test "broadcasts :agent_status_changed on status update", %{agent_id: agent_id} do
      # Drain the :agent_started event first
      assert_receive %{type: :agent_started}, 1000

      Server.update_status(agent_id, :running)

      assert_receive %{
                       type: :agent_status_changed,
                       payload: %{
                         agent_id: ^agent_id,
                         old_status: :idle,
                         new_status: :running
                       },
                       timestamp: %DateTime{}
                     },
                     1000
    end

    test "broadcasts correct old and new status on sequential transitions", %{
      agent_id: agent_id
    } do
      # Drain :agent_started
      assert_receive %{type: :agent_started}, 1000

      Server.update_status(agent_id, :running)

      assert_receive %{
                       type: :agent_status_changed,
                       payload: %{old_status: :idle, new_status: :running}
                     },
                     1000

      Server.update_status(agent_id, :done)

      assert_receive %{
                       type: :agent_status_changed,
                       payload: %{old_status: :running, new_status: :done}
                     },
                     1000
    end

    test "does not broadcast on invalid status update", %{agent_id: agent_id} do
      # Drain :agent_started
      assert_receive %{type: :agent_started}, 1000

      Server.update_status(agent_id, :paused)

      refute_receive %{type: :agent_status_changed}, 100
    end
  end

  describe "agent_work_assigned event" do
    test "broadcasts :agent_work_assigned on work assignment", %{agent_id: agent_id} do
      # Drain :agent_started
      assert_receive %{type: :agent_started}, 1000

      work = %{task: "research", topic: "elixir"}
      Server.assign_work(agent_id, work)

      assert_receive %{
                       type: :agent_work_assigned,
                       payload: %{agent_id: ^agent_id, work: ^work},
                       timestamp: %DateTime{}
                     },
                     1000
    end
  end

  describe "agent_stopped event" do
    test "broadcasts :agent_stopped on stop", %{agent_id: agent_id} do
      # Drain :agent_started
      assert_receive %{type: :agent_started}, 1000

      Server.stop(agent_id)

      assert_receive %{
                       type: :agent_stopped,
                       payload: %{agent_id: ^agent_id, reason: :normal},
                       timestamp: %DateTime{}
                     },
                     1000
    end
  end

  describe "multi-agent events" do
    test "events from different agents are received independently" do
      # Drain :agent_started from setup agent
      assert_receive %{type: :agent_started}, 1000

      config2 = Config.new!(%{name: "agent-two", role: "writer"})
      {:ok, pid2} = Server.start_link(config2)
      {:ok, state2} = GenServer.call(pid2, :get_state)
      agent_id2 = state2.id

      # Should receive :agent_started for agent 2
      assert_receive %{
                       type: :agent_started,
                       payload: %{agent_id: ^agent_id2, name: "agent-two", role: "writer"}
                     },
                     1000

      # Update status on agent 2
      Server.update_status(agent_id2, :running)

      assert_receive %{
                       type: :agent_status_changed,
                       payload: %{agent_id: ^agent_id2, new_status: :running}
                     },
                     1000

      # Cleanup
      Server.stop(agent_id2)
      assert_receive %{type: :agent_stopped, payload: %{agent_id: ^agent_id2}}, 1000
    end
  end

  describe "full lifecycle event sequence" do
    test "receives all events in order for a complete lifecycle", %{agent_id: agent_id} do
      # 1. :agent_started (from setup)
      assert_receive %{type: :agent_started, payload: %{agent_id: ^agent_id}}, 1000

      # 2. Assign work -> :agent_work_assigned + implicit :agent_status_changed
      Server.assign_work(agent_id, %{task: "build"})

      assert_receive %{type: :agent_work_assigned, payload: %{agent_id: ^agent_id}}, 1000

      # 3. Update to :done
      Server.update_status(agent_id, :done)

      assert_receive %{
                       type: :agent_status_changed,
                       payload: %{agent_id: ^agent_id, new_status: :done}
                     },
                     1000

      # 4. Stop
      Server.stop(agent_id)

      assert_receive %{
                       type: :agent_stopped,
                       payload: %{agent_id: ^agent_id, reason: :normal}
                     },
                     1000
    end
  end
end
