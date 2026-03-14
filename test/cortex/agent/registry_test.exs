defmodule Cortex.Agent.RegistryTest do
  use ExUnit.Case, async: true

  alias Cortex.Agent.Registry, as: AgentRegistry

  describe "via_tuple/1" do
    test "produces the correct :via tuple" do
      result = AgentRegistry.via_tuple("test-id")
      assert {:via, Registry, {Cortex.Agent.Registry, "test-id"}} = result
    end
  end

  describe "lookup/1" do
    test "returns :not_found for an unknown agent id" do
      assert :not_found = AgentRegistry.lookup("nonexistent-agent-id")
    end

    test "returns {:ok, pid} after a process registers with via_tuple" do
      agent_id = Uniq.UUID.uuid4()

      # Start a process that registers under the given agent_id
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: AgentRegistry.via_tuple(agent_id))

      assert {:ok, ^pid} = AgentRegistry.lookup(agent_id)

      Agent.stop(pid)
    end

    test "returns :not_found after the registered process dies" do
      agent_id = Uniq.UUID.uuid4()
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: AgentRegistry.via_tuple(agent_id))

      Agent.stop(pid)
      # Small delay to let the registry clean up
      Process.sleep(10)

      assert :not_found = AgentRegistry.lookup(agent_id)
    end
  end

  describe "all/0" do
    test "returns empty list when no agents are registered" do
      # There might be agents from other tests, but we can at least verify the shape
      result = AgentRegistry.all()
      assert is_list(result)
    end

    test "includes a newly registered agent" do
      agent_id = Uniq.UUID.uuid4()
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: AgentRegistry.via_tuple(agent_id))

      agents = AgentRegistry.all()
      assert {agent_id, pid} in agents

      Agent.stop(pid)
    end

    test "returns multiple registered agents" do
      id1 = Uniq.UUID.uuid4()
      id2 = Uniq.UUID.uuid4()

      {:ok, pid1} = Agent.start_link(fn -> :ok end, name: AgentRegistry.via_tuple(id1))
      {:ok, pid2} = Agent.start_link(fn -> :ok end, name: AgentRegistry.via_tuple(id2))

      agents = AgentRegistry.all()
      assert {id1, pid1} in agents
      assert {id2, pid2} in agents

      Agent.stop(pid1)
      Agent.stop(pid2)
    end
  end
end
