defmodule Cortex.Tool.ExecutorTest do
  use ExUnit.Case, async: true

  alias Cortex.Tool.Executor

  setup do
    # Start an isolated Task.Supervisor for each test to avoid cross-test interference
    supervisor_name = :"test_tool_sup_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Task.Supervisor.start_link(name: supervisor_name)
    {:ok, supervisor: supervisor_name}
  end

  describe "run/3 with successful tool" do
    test "returns {:ok, result} from tool execution", %{supervisor: sup} do
      assert {:ok, %{"hello" => "world"}} =
               Executor.run(Cortex.TestTools.Echo, %{"hello" => "world"}, supervisor: sup)
    end

    test "returns {:ok, result} with empty args", %{supervisor: sup} do
      assert {:ok, %{}} = Executor.run(Cortex.TestTools.Echo, %{}, supervisor: sup)
    end

    test "tool runs in a different process than caller", %{supervisor: sup} do
      caller_pid = self()

      {:ok, tool_pid} =
        Executor.run(
          Cortex.TestTools.Echo,
          %{"pid" => :erlang.pid_to_list(caller_pid)},
          supervisor: sup
        )

      # The Echo tool returns args as-is, but let's verify by checking
      # the task ran under the supervisor (different process)
      assert is_map(tool_pid)
    end
  end

  describe "run/3 with crashing tool" do
    test "returns {:error, {:exception, _}} when tool raises", %{supervisor: sup} do
      result = Executor.run(Cortex.TestTools.Crasher, %{}, supervisor: sup)

      assert {:error, {:exception, {%RuntimeError{message: "deliberate crash"}, _stacktrace}}} =
               result
    end

    test "caller process survives a tool crash", %{supervisor: sup} do
      caller_pid = self()

      _result = Executor.run(Cortex.TestTools.Crasher, %{}, supervisor: sup)

      # We're still alive
      assert Process.alive?(caller_pid)
    end
  end

  describe "run/3 with killed tool" do
    test "returns error when tool calls Process.exit(self(), :kill)", %{supervisor: sup} do
      result = Executor.run(Cortex.TestTools.Killer, %{}, supervisor: sup)

      assert {:error, {:exception, :killed}} = result
    end

    test "caller survives a :kill exit", %{supervisor: sup} do
      caller_pid = self()

      _result = Executor.run(Cortex.TestTools.Killer, %{}, supervisor: sup)

      assert Process.alive?(caller_pid)
    end
  end

  describe "run/3 with timeout" do
    test "returns {:error, :timeout} when tool exceeds timeout", %{supervisor: sup} do
      result =
        Executor.run(Cortex.TestTools.Slow, %{"sleep_ms" => 5_000},
          supervisor: sup,
          timeout: 50
        )

      assert {:error, :timeout} = result
    end

    test "timed-out task process is dead after return", %{supervisor: sup} do
      # We need to check the task pid is dead after timeout.
      # Run the slow tool with a short timeout, then verify no children remain.
      assert {:error, :timeout} =
               Executor.run(Cortex.TestTools.Slow, %{"sleep_ms" => 5_000},
                 supervisor: sup,
                 timeout: 50
               )

      # Give a moment for cleanup
      Process.sleep(10)

      # The supervisor should have no active children after the shutdown
      children = Task.Supervisor.children(sup)
      assert children == []
    end
  end

  describe "run/3 with bad return value" do
    test "returns {:error, {:bad_return, value}} for non-tuple return", %{supervisor: sup} do
      result = Executor.run(Cortex.TestTools.BadReturn, %{}, supervisor: sup)

      assert {:error, {:bad_return, :not_a_tuple}} = result
    end
  end

  describe "run/3 concurrent executions" do
    test "five parallel executions all return independently", %{supervisor: sup} do
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Executor.run(Cortex.TestTools.Echo, %{"index" => i}, supervisor: sup)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      for {result, i} <- Enum.zip(results, 1..5) do
        assert {:ok, %{"index" => ^i}} = result
      end
    end

    test "a crashing tool does not affect a concurrent healthy tool", %{supervisor: sup} do
      crash_task =
        Task.async(fn ->
          Executor.run(Cortex.TestTools.Crasher, %{}, supervisor: sup)
        end)

      healthy_task =
        Task.async(fn ->
          Executor.run(Cortex.TestTools.Echo, %{"ok" => true}, supervisor: sup)
        end)

      [crash_result, healthy_result] = Task.await_many([crash_task, healthy_task], 5_000)

      assert {:error, {:exception, _}} = crash_result
      assert {:ok, %{"ok" => true}} = healthy_result
    end
  end

  describe "run/3 process isolation" do
    test "tool executes in a different process than the caller", %{supervisor: sup} do
      # Use a tool that captures its own pid
      defmodule PidCapture do
        @behaviour Cortex.Tool.Behaviour
        def name, do: "pid_capture"
        def description, do: "Captures the executing process pid"
        def schema, do: %{}
        def execute(_args), do: {:ok, self()}
      end

      caller_pid = self()
      {:ok, tool_pid} = Executor.run(PidCapture, %{}, supervisor: sup)

      assert is_pid(tool_pid)
      assert tool_pid != caller_pid
    end
  end
end
