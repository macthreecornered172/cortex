defmodule Cortex.Agent.ConfigTest do
  use ExUnit.Case, async: true

  alias Cortex.Agent.Config

  describe "new/1" do
    test "valid config with all fields" do
      attrs = %{
        name: "researcher",
        role: "research lead",
        model: "opus",
        max_turns: 100,
        timeout_minutes: 60,
        metadata: %{team: "alpha"}
      }

      assert {:ok, %Config{} = config} = Config.new(attrs)
      assert config.name == "researcher"
      assert config.role == "research lead"
      assert config.model == "opus"
      assert config.max_turns == 100
      assert config.timeout_minutes == 60
      assert config.metadata == %{team: "alpha"}
    end

    test "valid config with only required fields applies defaults" do
      assert {:ok, %Config{} = config} = Config.new(%{name: "worker", role: "builder"})
      assert config.name == "worker"
      assert config.role == "builder"
      assert config.model == "sonnet"
      assert config.max_turns == 200
      assert config.timeout_minutes == 30
      assert config.metadata == %{}
    end

    test "accepts keyword list input" do
      assert {:ok, %Config{} = config} = Config.new(name: "worker", role: "builder")
      assert config.name == "worker"
      assert config.role == "builder"
    end

    test "missing name returns error" do
      assert {:error, errors} = Config.new(%{role: "builder"})
      assert "name is required" in errors
    end

    test "missing role returns error" do
      assert {:error, errors} = Config.new(%{name: "worker"})
      assert "role is required" in errors
    end

    test "empty string name returns error" do
      assert {:error, errors} = Config.new(%{name: "", role: "builder"})
      assert "name cannot be empty" in errors
    end

    test "blank string (whitespace only) role returns error" do
      assert {:error, errors} = Config.new(%{name: "worker", role: "   "})
      assert "role cannot be empty" in errors
    end

    test "non-positive max_turns returns error" do
      assert {:error, errors} = Config.new(%{name: "worker", role: "builder", max_turns: 0})
      assert "max_turns must be a positive integer" in errors
    end

    test "negative max_turns returns error" do
      assert {:error, errors} = Config.new(%{name: "worker", role: "builder", max_turns: -1})
      assert "max_turns must be a positive integer" in errors
    end

    test "non-integer max_turns returns error" do
      assert {:error, errors} = Config.new(%{name: "worker", role: "builder", max_turns: "abc"})
      assert "max_turns must be a positive integer" in errors
    end

    test "non-positive timeout_minutes returns error" do
      assert {:error, errors} =
               Config.new(%{name: "worker", role: "builder", timeout_minutes: 0})

      assert "timeout_minutes must be a positive integer" in errors
    end

    test "non-map metadata returns error" do
      assert {:error, errors} =
               Config.new(%{name: "worker", role: "builder", metadata: "not a map"})

      assert "metadata must be a map" in errors
    end

    test "non-string model returns error" do
      assert {:error, errors} = Config.new(%{name: "worker", role: "builder", model: 123})
      assert "model must be a string" in errors
    end

    test "multiple validation failures returns all errors" do
      assert {:error, errors} = Config.new(%{max_turns: -1, timeout_minutes: 0})
      assert "name is required" in errors
      assert "role is required" in errors
      assert "max_turns must be a positive integer" in errors
      assert "timeout_minutes must be a positive integer" in errors
      assert length(errors) == 4
    end

    test "missing both name and role returns both errors" do
      assert {:error, errors} = Config.new(%{})
      assert "name is required" in errors
      assert "role is required" in errors
    end
  end

  describe "new!/1" do
    test "returns struct on valid input" do
      config = Config.new!(%{name: "worker", role: "builder"})
      assert %Config{} = config
      assert config.name == "worker"
      assert config.role == "builder"
    end

    test "raises ArgumentError on invalid input" do
      assert_raise ArgumentError, ~r/invalid agent config/, fn ->
        Config.new!(%{})
      end
    end

    test "raises with all error messages in the exception" do
      error =
        assert_raise ArgumentError, fn ->
          Config.new!(%{max_turns: -1})
        end

      assert error.message =~ "name is required"
      assert error.message =~ "role is required"
      assert error.message =~ "max_turns must be a positive integer"
    end
  end
end
