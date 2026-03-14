defmodule CortexTest do
  use ExUnit.Case, async: true

  # Helper: find the agent ID registered to a given pid
  defp find_agent_id(pid) do
    {id, _} = Enum.find(Cortex.list_agents(), fn {_id, p} -> p == pid end)
    id
  end

  describe "start_agent/1" do
    test "starts an agent and returns {:ok, pid}" do
      config = %{name: "test-agent", role: "worker"}

      assert {:ok, pid} = Cortex.start_agent(config)
      assert is_pid(pid)
      assert Process.alive?(pid)

      agent_id = find_agent_id(pid)
      Cortex.stop_agent(agent_id)
    end
  end

  describe "stop_agent/1" do
    test "stops a running agent" do
      {:ok, pid} = Cortex.start_agent(%{name: "test-agent", role: "worker"})
      agent_id = find_agent_id(pid)

      assert :ok = Cortex.stop_agent(agent_id)

      Process.sleep(10)
      refute Process.alive?(pid)
    end

    test "returns {:error, :not_found} for unknown agent" do
      assert {:error, :not_found} = Cortex.stop_agent("nonexistent-id")
    end
  end

  describe "list_agents/0" do
    test "returns a list of {id, pid} pairs" do
      assert is_list(Cortex.list_agents())
    end

    test "includes started agents" do
      {:ok, pid1} = Cortex.start_agent(%{name: "agent-1", role: "worker"})
      {:ok, pid2} = Cortex.start_agent(%{name: "agent-2", role: "worker"})

      id1 = find_agent_id(pid1)
      id2 = find_agent_id(pid2)

      agents = Cortex.list_agents()
      assert {id1, pid1} in agents
      assert {id2, pid2} in agents

      Cortex.stop_agent(id1)
      Cortex.stop_agent(id2)
    end

    test "does not include stopped agents" do
      {:ok, pid} = Cortex.start_agent(%{name: "test-agent", role: "worker"})
      agent_id = find_agent_id(pid)

      Cortex.stop_agent(agent_id)
      Process.sleep(10)

      agents = Cortex.list_agents()
      refute Enum.any?(agents, fn {id, _} -> id == agent_id end)
    end
  end

  describe "end-to-end workflow" do
    test "start, list, stop lifecycle" do
      {:ok, pid} = Cortex.start_agent(%{name: "lifecycle-test", role: "worker"})
      agent_id = find_agent_id(pid)

      assert {agent_id, pid} in Cortex.list_agents()

      :ok = Cortex.stop_agent(agent_id)
      Process.sleep(10)
      refute Enum.any?(Cortex.list_agents(), fn {id, _} -> id == agent_id end)
    end
  end
end
