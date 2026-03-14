defmodule Cortex.ApplicationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Integration tests verifying the Application supervision tree boots correctly
  and all named processes are alive.
  """

  describe "application boot" do
    test "Cortex.PubSub is alive" do
      assert Process.whereis(Cortex.PubSub) |> is_pid()
    end

    test "Cortex.Agent.Registry is alive" do
      assert Process.whereis(Cortex.Agent.Registry) |> is_pid()
    end

    test "Cortex.Agent.Supervisor (DynamicSupervisor) is alive" do
      assert Process.whereis(Cortex.Agent.Supervisor) |> is_pid()
    end

    test "Cortex.Tool.Supervisor (Task.Supervisor) is alive" do
      assert Process.whereis(Cortex.Tool.Supervisor) |> is_pid()
    end

    test "Cortex.Tool.Registry is alive" do
      assert Process.whereis(Cortex.Tool.Registry) |> is_pid()
    end

    test "all five supervised processes are alive simultaneously" do
      pids = [
        Process.whereis(Cortex.PubSub),
        Process.whereis(Cortex.Agent.Registry),
        Process.whereis(Cortex.Agent.Supervisor),
        Process.whereis(Cortex.Tool.Supervisor),
        Process.whereis(Cortex.Tool.Registry)
      ]

      assert Enum.all?(pids, &is_pid/1),
             "Expected all five supervised processes to be alive, got: #{inspect(pids)}"
    end
  end
end
