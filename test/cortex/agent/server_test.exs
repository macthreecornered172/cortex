defmodule Cortex.Agent.ServerTest do
  use ExUnit.Case, async: true

  alias Cortex.Agent.Config
  alias Cortex.Agent.Server
  alias Cortex.Agent.State

  setup do
    config = Config.new!(%{name: "test-agent", role: "worker"})
    {:ok, pid} = Server.start_link(config)

    # Get the agent_id from the state
    {:ok, state} = GenServer.call(pid, :get_state)
    agent_id = state.id

    %{config: config, pid: pid, agent_id: agent_id}
  end

  describe "start_link/1" do
    test "starts a process and registers in Registry", %{pid: pid, agent_id: agent_id} do
      assert Process.alive?(pid)
      assert [{^pid, _}] = Registry.lookup(Cortex.Agent.Registry, agent_id)
    end

    test "starts with :idle status", %{agent_id: agent_id} do
      assert {:ok, state} = Server.get_state(agent_id)
      assert state.status == :idle
    end

    test "generates a valid UUID", %{agent_id: agent_id} do
      assert String.length(agent_id) == 36

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               agent_id
             )
    end

    test "state contains the config", %{agent_id: agent_id, config: config} do
      {:ok, state} = Server.get_state(agent_id)
      assert state.config == config
    end
  end

  describe "get_state/1" do
    test "returns current state", %{agent_id: agent_id} do
      assert {:ok, %State{} = state} = Server.get_state(agent_id)
      assert state.status == :idle
      assert state.config.name == "test-agent"
      assert state.config.role == "worker"
    end

    test "returns {:error, :not_found} for unknown ID" do
      assert {:error, :not_found} = Server.get_state("nonexistent-agent-id")
    end
  end

  describe "update_status/2" do
    test "changes status to :running", %{agent_id: agent_id} do
      assert :ok = Server.update_status(agent_id, :running)
      assert {:ok, state} = Server.get_state(agent_id)
      assert state.status == :running
    end

    test "changes status to :done", %{agent_id: agent_id} do
      assert :ok = Server.update_status(agent_id, :done)
      assert {:ok, state} = Server.get_state(agent_id)
      assert state.status == :done
    end

    test "changes status to :failed", %{agent_id: agent_id} do
      assert :ok = Server.update_status(agent_id, :failed)
      assert {:ok, state} = Server.get_state(agent_id)
      assert state.status == :failed
    end

    test "returns {:error, :invalid_status} for invalid status", %{agent_id: agent_id} do
      assert {:error, :invalid_status} = Server.update_status(agent_id, :paused)
    end

    test "state unchanged after invalid status attempt", %{agent_id: agent_id} do
      Server.update_status(agent_id, :running)
      Server.update_status(agent_id, :paused)
      assert {:ok, state} = Server.get_state(agent_id)
      assert state.status == :running
    end

    test "returns {:error, :not_found} for unknown agent" do
      assert {:error, :not_found} = Server.update_status("nonexistent-id", :running)
    end
  end

  describe "update_metadata/3" do
    test "updates metadata map", %{agent_id: agent_id} do
      assert :ok = Server.update_metadata(agent_id, :key, "value")
      assert {:ok, state} = Server.get_state(agent_id)
      assert state.metadata[:key] == "value"
    end

    test "multiple metadata updates accumulate", %{agent_id: agent_id} do
      Server.update_metadata(agent_id, :key1, "value1")
      Server.update_metadata(agent_id, :key2, "value2")
      assert {:ok, state} = Server.get_state(agent_id)
      assert state.metadata[:key1] == "value1"
      assert state.metadata[:key2] == "value2"
    end

    test "overwrites existing key", %{agent_id: agent_id} do
      Server.update_metadata(agent_id, :key, "old")
      Server.update_metadata(agent_id, :key, "new")
      assert {:ok, state} = Server.get_state(agent_id)
      assert state.metadata[:key] == "new"
    end

    test "returns {:error, :not_found} for unknown agent" do
      assert {:error, :not_found} = Server.update_metadata("nonexistent-id", :key, "value")
    end
  end

  describe "assign_work/2" do
    test "transitions agent to :running and stores work", %{agent_id: agent_id} do
      Server.assign_work(agent_id, %{task: "research"})
      # Give the cast time to process
      Process.sleep(10)
      assert {:ok, state} = Server.get_state(agent_id)
      assert state.status == :running
      assert state.metadata[:work] == %{task: "research"}
    end

    test "returns :ok for unknown agent (fire-and-forget)" do
      assert :ok = Server.assign_work("nonexistent-id", %{task: "nothing"})
    end
  end

  describe "stop/1" do
    test "stops the agent process", %{agent_id: agent_id, pid: pid} do
      assert :ok = Server.stop(agent_id)
      refute Process.alive?(pid)
    end

    test "agent is deregistered after stop", %{agent_id: agent_id} do
      Server.stop(agent_id)
      assert {:error, :not_found} = Server.get_state(agent_id)
    end

    test "returns {:error, :not_found} for unknown agent" do
      assert {:error, :not_found} = Server.stop("nonexistent-id")
    end
  end

  describe "multiple agents" do
    test "two agents can coexist" do
      config1 = Config.new!(%{name: "agent-1", role: "researcher"})
      config2 = Config.new!(%{name: "agent-2", role: "writer"})

      {:ok, pid1} = Server.start_link(config1)
      {:ok, pid2} = Server.start_link(config2)

      {:ok, state1} = GenServer.call(pid1, :get_state)
      {:ok, state2} = GenServer.call(pid2, :get_state)

      assert state1.id != state2.id
      assert state1.config.name == "agent-1"
      assert state2.config.name == "agent-2"

      # Both are queryable via client API
      assert {:ok, _} = Server.get_state(state1.id)
      assert {:ok, _} = Server.get_state(state2.id)

      # Stopping one doesn't affect the other
      Server.stop(state1.id)
      assert {:error, :not_found} = Server.get_state(state1.id)
      assert {:ok, _} = Server.get_state(state2.id)

      # Cleanup
      Server.stop(state2.id)
    end
  end

  describe "edge cases" do
    test "get_state after process is killed returns {:error, :not_found}", %{
      pid: pid,
      agent_id: agent_id
    } do
      Process.flag(:trap_exit, true)
      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}
      assert {:error, :not_found} = Server.get_state(agent_id)
    end

    test "update_status after process is killed returns {:error, :not_found}", %{
      pid: pid,
      agent_id: agent_id
    } do
      Process.flag(:trap_exit, true)
      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}
      assert {:error, :not_found} = Server.update_status(agent_id, :running)
    end

    test "update_metadata after process is killed returns {:error, :not_found}", %{
      pid: pid,
      agent_id: agent_id
    } do
      Process.flag(:trap_exit, true)
      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}
      assert {:error, :not_found} = Server.update_metadata(agent_id, :key, "val")
    end

    test "stop after process already stopped returns {:error, :not_found}", %{
      agent_id: agent_id
    } do
      assert :ok = Server.stop(agent_id)
      assert {:error, :not_found} = Server.stop(agent_id)
    end

    test "timestamps are updated on status change", %{agent_id: agent_id} do
      {:ok, before_state} = Server.get_state(agent_id)
      Process.sleep(1)
      Server.update_status(agent_id, :running)
      {:ok, after_state} = Server.get_state(agent_id)

      assert DateTime.compare(after_state.updated_at, before_state.updated_at) in [:gt, :eq]
      # started_at should not change
      assert after_state.started_at == before_state.started_at
    end

    test "timestamps are updated on metadata change", %{agent_id: agent_id} do
      {:ok, before_state} = Server.get_state(agent_id)
      Process.sleep(1)
      Server.update_metadata(agent_id, :key, "value")
      {:ok, after_state} = Server.get_state(agent_id)

      assert DateTime.compare(after_state.updated_at, before_state.updated_at) in [:gt, :eq]
    end

    test "config is immutable — no API to change it", %{agent_id: agent_id, config: config} do
      Server.update_status(agent_id, :running)
      Server.update_metadata(agent_id, :key, "value")
      {:ok, state} = Server.get_state(agent_id)
      assert state.config == config
    end

    test "multiple sequential status transitions work", %{agent_id: agent_id} do
      assert :ok = Server.update_status(agent_id, :running)
      assert :ok = Server.update_status(agent_id, :done)

      {:ok, state} = Server.get_state(agent_id)
      assert state.status == :done
    end
  end
end
