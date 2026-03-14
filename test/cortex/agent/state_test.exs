defmodule Cortex.Agent.StateTest do
  use ExUnit.Case, async: true

  alias Cortex.Agent.Config
  alias Cortex.Agent.State

  setup do
    config = Config.new!(%{name: "test-agent", role: "worker"})
    state = State.new(config)
    %{config: config, state: state}
  end

  describe "new/1" do
    test "creates state with generated UUID", %{state: state} do
      assert is_binary(state.id)
      assert String.length(state.id) == 36
      # UUID format: 8-4-4-4-12
      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               state.id
             )
    end

    test "creates state with :idle status", %{state: state} do
      assert state.status == :idle
    end

    test "sets timestamps", %{state: state} do
      assert %DateTime{} = state.started_at
      assert %DateTime{} = state.updated_at
      assert state.started_at == state.updated_at
    end

    test "config in state matches input config", %{config: config, state: state} do
      assert state.config == config
      assert state.config.name == "test-agent"
      assert state.config.role == "worker"
    end

    test "metadata defaults to config metadata", %{state: state} do
      assert state.metadata == %{}
    end

    test "metadata inherits from config metadata" do
      config = Config.new!(%{name: "agent", role: "worker", metadata: %{team: "alpha"}})
      state = State.new(config)
      assert state.metadata == %{team: "alpha"}
    end

    test "each new state gets a unique ID" do
      config = Config.new!(%{name: "agent", role: "worker"})
      state1 = State.new(config)
      state2 = State.new(config)
      assert state1.id != state2.id
    end
  end

  describe "update_status/2" do
    test "valid status :running returns updated state", %{state: state} do
      assert {:ok, updated} = State.update_status(state, :running)
      assert updated.status == :running
    end

    test "valid status :done returns updated state", %{state: state} do
      assert {:ok, updated} = State.update_status(state, :done)
      assert updated.status == :done
    end

    test "valid status :failed returns updated state", %{state: state} do
      assert {:ok, updated} = State.update_status(state, :failed)
      assert updated.status == :failed
    end

    test "valid status :idle returns updated state", %{state: state} do
      assert {:ok, updated} = State.update_status(state, :idle)
      assert updated.status == :idle
    end

    test "updates updated_at timestamp", %{state: state} do
      # Small sleep to ensure timestamp differs
      Process.sleep(1)
      assert {:ok, updated} = State.update_status(state, :running)
      assert DateTime.compare(updated.updated_at, state.updated_at) in [:gt, :eq]
    end

    test "does not change other fields", %{state: state} do
      assert {:ok, updated} = State.update_status(state, :running)
      assert updated.id == state.id
      assert updated.config == state.config
      assert updated.metadata == state.metadata
      assert updated.started_at == state.started_at
    end

    test "invalid status atom returns error", %{state: state} do
      assert {:error, :invalid_status} = State.update_status(state, :paused)
    end

    test "non-atom status returns error", %{state: state} do
      assert {:error, :invalid_status} = State.update_status(state, "running")
    end

    test "nil status returns error", %{state: state} do
      assert {:error, :invalid_status} = State.update_status(state, nil)
    end
  end

  describe "update_metadata/3" do
    test "sets a new key in metadata", %{state: state} do
      updated = State.update_metadata(state, :work, %{task: "research"})
      assert updated.metadata[:work] == %{task: "research"}
    end

    test "overwrites existing key", %{state: state} do
      state = State.update_metadata(state, :key, "old")
      updated = State.update_metadata(state, :key, "new")
      assert updated.metadata[:key] == "new"
    end

    test "updates updated_at timestamp", %{state: state} do
      Process.sleep(1)
      updated = State.update_metadata(state, :key, "value")
      assert DateTime.compare(updated.updated_at, state.updated_at) in [:gt, :eq]
    end

    test "does not change other fields", %{state: state} do
      updated = State.update_metadata(state, :key, "value")
      assert updated.id == state.id
      assert updated.config == state.config
      assert updated.status == state.status
      assert updated.started_at == state.started_at
    end

    test "supports any term as key and value", %{state: state} do
      updated = State.update_metadata(state, "string_key", [1, 2, 3])
      assert updated.metadata["string_key"] == [1, 2, 3]
    end
  end

  describe "valid_statuses/0" do
    test "returns all four valid status atoms" do
      assert State.valid_statuses() == [:idle, :running, :done, :failed]
    end
  end
end
