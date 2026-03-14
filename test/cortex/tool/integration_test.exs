defmodule Cortex.Tool.IntegrationTest do
  use ExUnit.Case, async: true

  alias Cortex.Tool.{Executor, Registry}
  alias Cortex.Tool.Builtin.Shell

  setup do
    # Start isolated supervisor and registry for each test
    suffix = System.unique_integer([:positive])
    supervisor_name = :"integration_tool_sup_#{suffix}"
    registry_name = :"integration_tool_reg_#{suffix}"

    {:ok, _sup_pid} = Task.Supervisor.start_link(name: supervisor_name)
    {:ok, _reg_pid} = Registry.start_link(name: registry_name)

    {:ok, supervisor: supervisor_name, registry: registry_name}
  end

  describe "end-to-end: supervisor + registry + executor + shell" do
    test "register shell tool, look it up, execute via executor", %{
      supervisor: sup,
      registry: reg
    } do
      # Register the Shell tool
      :ok = Registry.register(Shell, reg)

      # Look it up by name
      {:ok, tool_module} = Registry.lookup("shell", reg)
      assert tool_module == Shell

      # Execute it via the Executor
      {:ok, output} =
        Executor.run(tool_module, %{"command" => "echo", "args" => ["integration test"]},
          supervisor: sup
        )

      assert String.trim(output) == "integration test"
    end
  end

  describe "register multiple tools, look up by name, execute each" do
    test "all registered tools are callable via executor", %{supervisor: sup, registry: reg} do
      # Register multiple tools
      :ok = Registry.register(Cortex.TestTools.Echo, reg)
      :ok = Registry.register(Shell, reg)

      # Look up and execute Echo
      {:ok, echo_module} = Registry.lookup("echo", reg)
      {:ok, result} = Executor.run(echo_module, %{"data" => "hello"}, supervisor: sup)
      assert result == %{"data" => "hello"}

      # Look up and execute Shell
      {:ok, shell_module} = Registry.lookup("shell", reg)
      {:ok, output} = Executor.run(shell_module, %{"command" => "pwd"}, supervisor: sup)
      assert String.trim(output) != ""
    end

    test "list shows all registered tools", %{registry: reg} do
      :ok = Registry.register(Cortex.TestTools.Echo, reg)
      :ok = Registry.register(Shell, reg)
      :ok = Registry.register(Cortex.TestTools.Slow, reg)

      modules = Registry.list(reg)
      assert length(modules) == 3
      assert Cortex.TestTools.Echo in modules
      assert Shell in modules
      assert Cortex.TestTools.Slow in modules
    end
  end

  describe "crash isolation across executions" do
    test "crashing tool does not corrupt the supervisor — healthy tool succeeds after", %{
      supervisor: sup,
      registry: reg
    } do
      :ok = Registry.register(Cortex.TestTools.Crasher, reg)
      :ok = Registry.register(Cortex.TestTools.Echo, reg)

      # Execute crashing tool
      {:ok, crasher_module} = Registry.lookup("crasher", reg)
      result = Executor.run(crasher_module, %{}, supervisor: sup)
      assert {:error, {:exception, _}} = result

      # Execute healthy tool — should succeed despite the previous crash
      {:ok, echo_module} = Registry.lookup("echo", reg)
      assert {:ok, %{"ok" => true}} = Executor.run(echo_module, %{"ok" => true}, supervisor: sup)
    end

    test "killed tool does not corrupt the supervisor — healthy tool succeeds after", %{
      supervisor: sup,
      registry: reg
    } do
      :ok = Registry.register(Cortex.TestTools.Killer, reg)
      :ok = Registry.register(Cortex.TestTools.Echo, reg)

      # Execute killer tool
      {:ok, killer_module} = Registry.lookup("killer", reg)
      result = Executor.run(killer_module, %{}, supervisor: sup)
      assert {:error, {:exception, :killed}} = result

      # Execute healthy tool — should succeed
      {:ok, echo_module} = Registry.lookup("echo", reg)

      assert {:ok, %{"still" => "alive"}} =
               Executor.run(echo_module, %{"still" => "alive"}, supervisor: sup)
    end

    test "timed-out tool does not corrupt the supervisor — healthy tool succeeds after", %{
      supervisor: sup,
      registry: reg
    } do
      :ok = Registry.register(Cortex.TestTools.Slow, reg)
      :ok = Registry.register(Cortex.TestTools.Echo, reg)

      # Execute slow tool with short timeout
      {:ok, slow_module} = Registry.lookup("slow", reg)

      result =
        Executor.run(slow_module, %{"sleep_ms" => 5_000}, supervisor: sup, timeout: 50)

      assert {:error, :timeout} = result

      # Execute healthy tool — should succeed
      {:ok, echo_module} = Registry.lookup("echo", reg)

      assert {:ok, %{"after" => "timeout"}} =
               Executor.run(echo_module, %{"after" => "timeout"}, supervisor: sup)
    end
  end

  describe "concurrent tool executions through the full stack" do
    test "multiple tools run concurrently and return independently", %{
      supervisor: sup,
      registry: reg
    } do
      :ok = Registry.register(Cortex.TestTools.Echo, reg)
      :ok = Registry.register(Shell, reg)

      {:ok, echo_module} = Registry.lookup("echo", reg)
      {:ok, shell_module} = Registry.lookup("shell", reg)

      tasks = [
        Task.async(fn ->
          Executor.run(echo_module, %{"index" => 1}, supervisor: sup)
        end),
        Task.async(fn ->
          Executor.run(shell_module, %{"command" => "echo", "args" => ["concurrent"]},
            supervisor: sup
          )
        end),
        Task.async(fn ->
          Executor.run(echo_module, %{"index" => 3}, supervisor: sup)
        end)
      ]

      results = Task.await_many(tasks, 5_000)

      assert {:ok, %{"index" => 1}} = Enum.at(results, 0)
      assert {:ok, output} = Enum.at(results, 1)
      assert String.trim(output) == "concurrent"
      assert {:ok, %{"index" => 3}} = Enum.at(results, 2)
    end
  end
end
