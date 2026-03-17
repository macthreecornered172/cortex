defmodule Cortex.InternalAgent.LauncherTest do
  use ExUnit.Case, async: true

  alias Cortex.InternalAgent.Launcher
  alias Cortex.InternalAgent.SpawnConfig

  # Build a SpawnConfig that uses a mock command which immediately exits
  # with a valid NDJSON result line on stdout.
  defp mock_config(command) do
    %SpawnConfig{
      team_name: "test-agent",
      prompt: "test",
      model: "haiku",
      max_turns: 1,
      permission_mode: "bypassPermissions",
      timeout_minutes: 1,
      command: command
    }
  end

  describe "stop/1" do
    test "no-ops on nil" do
      assert Launcher.stop(nil) == :ok
    end

    test "stops a running task" do
      task = Task.async(fn -> Process.sleep(60_000) end)
      assert Launcher.stop(task) == :ok
    end

    test "handles already-finished task" do
      task = Task.async(fn -> :done end)
      # Let it finish
      Process.sleep(50)
      assert Launcher.stop(task) == :ok
    end
  end

  describe "run_async/1" do
    test "returns a Task struct" do
      # Use a command that will fail fast — we just need to verify we get a Task back
      config = mock_config("echo")
      task = Launcher.run_async(config)

      assert %Task{} = task
      # Clean up
      Launcher.stop(task)
    end
  end
end
