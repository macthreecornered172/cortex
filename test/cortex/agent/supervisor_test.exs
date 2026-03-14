defmodule Cortex.Agent.SupervisorTest do
  use ExUnit.Case, async: true

  alias Cortex.Agent.Supervisor, as: AgentSupervisor
  alias Cortex.Agent.Registry, as: AgentRegistry

  # Helper: find the agent ID registered to a given pid
  defp find_agent_id(pid) do
    {id, _} = Enum.find(AgentSupervisor.list_agents(), fn {_id, p} -> p == pid end)
    id
  end

  describe "start_agent/1" do
    test "starts an agent process and returns {:ok, pid}" do
      config = %{name: "test-agent", role: "worker"}

      assert {:ok, pid} = AgentSupervisor.start_agent(config)
      assert is_pid(pid)
      assert Process.alive?(pid)

      agent_id = find_agent_id(pid)
      AgentSupervisor.stop_agent(agent_id)
    end

    test "started agent is registered in the registry" do
      config = %{name: "test-agent", role: "worker"}

      {:ok, pid} = AgentSupervisor.start_agent(config)
      agent_id = find_agent_id(pid)

      assert {:ok, ^pid} = AgentRegistry.lookup(agent_id)

      AgentSupervisor.stop_agent(agent_id)
    end

    test "started agent appears in list_agents" do
      config = %{name: "test-agent", role: "worker"}

      {:ok, pid} = AgentSupervisor.start_agent(config)
      agent_id = find_agent_id(pid)

      agents = AgentSupervisor.list_agents()
      assert {agent_id, pid} in agents

      AgentSupervisor.stop_agent(agent_id)
    end

    test "returns error for invalid config" do
      assert {:error, _} = AgentSupervisor.start_agent(%{name: "", role: ""})
    end
  end

  describe "stop_agent/1" do
    test "stops a running agent and returns :ok" do
      config = %{name: "test-agent", role: "worker"}

      {:ok, pid} = AgentSupervisor.start_agent(config)
      agent_id = find_agent_id(pid)

      assert :ok = AgentSupervisor.stop_agent(agent_id)

      Process.sleep(10)
      refute Process.alive?(pid)
      assert :not_found = AgentRegistry.lookup(agent_id)
    end

    test "returns {:error, :not_found} for an unknown agent id" do
      assert {:error, :not_found} = AgentSupervisor.stop_agent("nonexistent-agent-id")
    end

    test "stopped agent no longer appears in list_agents" do
      config = %{name: "test-agent", role: "worker"}

      {:ok, pid} = AgentSupervisor.start_agent(config)
      agent_id = find_agent_id(pid)

      AgentSupervisor.stop_agent(agent_id)
      Process.sleep(10)

      agents = AgentSupervisor.list_agents()
      refute Enum.any?(agents, fn {id, _pid} -> id == agent_id end)
    end
  end

  describe "list_agents/0" do
    test "returns a list" do
      assert is_list(AgentSupervisor.list_agents())
    end

    test "returns multiple agents" do
      {:ok, pid1} = AgentSupervisor.start_agent(%{name: "agent-1", role: "worker"})
      {:ok, pid2} = AgentSupervisor.start_agent(%{name: "agent-2", role: "worker"})

      id1 = find_agent_id(pid1)
      id2 = find_agent_id(pid2)

      agents = AgentSupervisor.list_agents()
      assert {id1, pid1} in agents
      assert {id2, pid2} in agents

      AgentSupervisor.stop_agent(id1)
      AgentSupervisor.stop_agent(id2)
    end
  end
end
