defmodule Cortex.Tool.RegistryTest do
  use ExUnit.Case, async: true

  alias Cortex.Tool.Registry

  setup do
    # Start an isolated registry Agent for each test
    registry_name = :"test_tool_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(name: registry_name)
    {:ok, registry: registry_name}
  end

  describe "register/2 + lookup/2 roundtrip" do
    test "registering a tool and looking it up by name", %{registry: reg} do
      assert :ok = Registry.register(Cortex.TestTools.Echo, reg)
      assert {:ok, Cortex.TestTools.Echo} = Registry.lookup("echo", reg)
    end

    test "registering multiple tools", %{registry: reg} do
      assert :ok = Registry.register(Cortex.TestTools.Echo, reg)
      assert :ok = Registry.register(Cortex.TestTools.Slow, reg)

      assert {:ok, Cortex.TestTools.Echo} = Registry.lookup("echo", reg)
      assert {:ok, Cortex.TestTools.Slow} = Registry.lookup("slow", reg)
    end
  end

  describe "lookup/2" do
    test "returns {:error, :not_found} for unregistered tool name", %{registry: reg} do
      assert {:error, :not_found} = Registry.lookup("nonexistent", reg)
    end
  end

  describe "list/1" do
    test "returns empty list when no tools registered", %{registry: reg} do
      assert [] = Registry.list(reg)
    end

    test "returns all registered tool modules", %{registry: reg} do
      :ok = Registry.register(Cortex.TestTools.Echo, reg)
      :ok = Registry.register(Cortex.TestTools.Slow, reg)
      :ok = Registry.register(Cortex.TestTools.Crasher, reg)

      modules = Registry.list(reg)
      assert length(modules) == 3
      assert Cortex.TestTools.Echo in modules
      assert Cortex.TestTools.Slow in modules
      assert Cortex.TestTools.Crasher in modules
    end
  end

  describe "register/2 with invalid module" do
    test "returns {:error, :invalid_tool} for a module without the behaviour callbacks", %{
      registry: reg
    } do
      # String is a real module but doesn't implement Tool.Behaviour
      assert {:error, :invalid_tool} = Registry.register(String, reg)
    end

    test "returns {:error, :invalid_tool} for a module missing some callbacks", %{registry: reg} do
      defmodule PartialTool do
        def name, do: "partial"
        def description, do: "Only has name and description"
        # Missing schema/0 and execute/1
      end

      assert {:error, :invalid_tool} = Registry.register(PartialTool, reg)
    end
  end

  describe "last-write-wins semantics" do
    test "re-registering with same name overwrites the previous module", %{registry: reg} do
      # Create two tools with the same name
      defmodule ToolV1 do
        @behaviour Cortex.Tool.Behaviour
        def name, do: "versioned_tool"
        def description, do: "Version 1"
        def schema, do: %{}
        def execute(_args), do: {:ok, :v1}
      end

      defmodule ToolV2 do
        @behaviour Cortex.Tool.Behaviour
        def name, do: "versioned_tool"
        def description, do: "Version 2"
        def schema, do: %{}
        def execute(_args), do: {:ok, :v2}
      end

      :ok = Registry.register(ToolV1, reg)
      assert {:ok, ToolV1} = Registry.lookup("versioned_tool", reg)

      :ok = Registry.register(ToolV2, reg)
      assert {:ok, ToolV2} = Registry.lookup("versioned_tool", reg)
    end

    test "list returns only the latest module for a given name", %{registry: reg} do
      defmodule ToolA do
        @behaviour Cortex.Tool.Behaviour
        def name, do: "shared_name"
        def description, do: "Tool A"
        def schema, do: %{}
        def execute(_args), do: {:ok, :a}
      end

      defmodule ToolB do
        @behaviour Cortex.Tool.Behaviour
        def name, do: "shared_name"
        def description, do: "Tool B"
        def schema, do: %{}
        def execute(_args), do: {:ok, :b}
      end

      :ok = Registry.register(ToolA, reg)
      :ok = Registry.register(ToolB, reg)

      modules = Registry.list(reg)
      assert length(modules) == 1
      assert ToolB in modules
    end
  end
end
