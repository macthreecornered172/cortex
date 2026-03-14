defmodule Cortex.Tool.BehaviourTest do
  use ExUnit.Case, async: true

  defmodule MinimalTool do
    @behaviour Cortex.Tool.Behaviour

    @impl true
    def name, do: "minimal_tool"

    @impl true
    def description, do: "A minimal tool for testing the behaviour contract"

    @impl true
    def schema do
      %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string"}
        }
      }
    end

    @impl true
    def execute(%{"input" => input}), do: {:ok, input}
    def execute(_args), do: {:error, :missing_input}
  end

  describe "behaviour contract" do
    test "name/0 returns a string" do
      assert is_binary(MinimalTool.name())
      assert MinimalTool.name() == "minimal_tool"
    end

    test "description/0 returns a string" do
      assert is_binary(MinimalTool.description())
    end

    test "schema/0 returns a map" do
      assert is_map(MinimalTool.schema())
      assert MinimalTool.schema()["type"] == "object"
    end

    test "execute/1 returns {:ok, result} on success" do
      assert {:ok, "hello"} = MinimalTool.execute(%{"input" => "hello"})
    end

    test "execute/1 returns {:error, reason} on failure" do
      assert {:error, :missing_input} = MinimalTool.execute(%{})
    end

    test "module exports all four callbacks" do
      assert function_exported?(MinimalTool, :name, 0)
      assert function_exported?(MinimalTool, :description, 0)
      assert function_exported?(MinimalTool, :schema, 0)
      assert function_exported?(MinimalTool, :execute, 1)
    end
  end
end
