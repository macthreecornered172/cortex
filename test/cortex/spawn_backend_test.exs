defmodule Cortex.SpawnBackendTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cortex.MockSpawnBackend

  setup :verify_on_exit!

  describe "spawn/1 -> stream/1 -> stop/1 lifecycle" do
    test "completes a full lifecycle" do
      handle = make_ref()
      chunks = ["line 1\n", "line 2\n", "{\"type\":\"result\"}\n"]

      MockSpawnBackend
      |> expect(:spawn, fn config ->
        assert config.backend == :local
        assert config.command == "claude"
        {:ok, handle}
      end)
      |> expect(:stream, fn h ->
        assert h == handle
        {:ok, chunks}
      end)
      |> expect(:stop, fn h ->
        assert h == handle
        :ok
      end)

      assert {:ok, ^handle} = MockSpawnBackend.spawn(%{backend: :local, command: "claude"})
      assert {:ok, stream} = MockSpawnBackend.stream(handle)

      collected = Enum.to_list(stream)
      assert length(collected) == 3
      assert hd(collected) == "line 1\n"

      assert :ok = MockSpawnBackend.stop(handle)
    end
  end

  describe "spawn/1 error handling" do
    test "returns {:error, reason} when spawning fails" do
      MockSpawnBackend
      |> expect(:spawn, fn _config ->
        {:error, :command_not_found}
      end)

      assert {:error, :command_not_found} =
               MockSpawnBackend.spawn(%{backend: :local, command: "nonexistent"})
    end
  end

  describe "status/1" do
    test "returns :running for an active process" do
      handle = make_ref()

      MockSpawnBackend
      |> expect(:spawn, fn _config -> {:ok, handle} end)
      |> expect(:status, fn h ->
        assert h == handle
        :running
      end)

      {:ok, h} = MockSpawnBackend.spawn(%{backend: :local})
      assert :running = MockSpawnBackend.status(h)
    end

    test "returns :done for a completed process" do
      handle = make_ref()

      MockSpawnBackend
      |> expect(:spawn, fn _config -> {:ok, handle} end)
      |> expect(:status, fn _h -> :done end)

      {:ok, h} = MockSpawnBackend.spawn(%{backend: :local})
      assert :done = MockSpawnBackend.status(h)
    end

    test "returns :failed for a crashed process" do
      handle = make_ref()

      MockSpawnBackend
      |> expect(:spawn, fn _config -> {:ok, handle} end)
      |> expect(:status, fn _h -> :failed end)

      {:ok, h} = MockSpawnBackend.spawn(%{backend: :local})
      assert :failed = MockSpawnBackend.status(h)
    end
  end

  describe "stop/1 idempotency" do
    test "can be called multiple times safely" do
      handle = make_ref()

      MockSpawnBackend
      |> expect(:spawn, fn _config -> {:ok, handle} end)
      |> expect(:stop, 2, fn _h -> :ok end)

      {:ok, h} = MockSpawnBackend.spawn(%{backend: :local})
      assert :ok = MockSpawnBackend.stop(h)
      assert :ok = MockSpawnBackend.stop(h)
    end
  end

  describe "stream/1 returns binary chunks" do
    test "returns enumerable of raw binary data" do
      handle = make_ref()

      # Simulate a backend that streams raw bytes including partial lines
      raw_chunks = [
        ~s({"type":"system","sub),
        ~s(type":"init","session_id":"abc"}\n),
        ~s({"type":"result","result":"done"}\n)
      ]

      MockSpawnBackend
      |> expect(:spawn, fn _config -> {:ok, handle} end)
      |> expect(:stream, fn _h -> {:ok, raw_chunks} end)

      {:ok, h} = MockSpawnBackend.spawn(%{backend: :local})
      {:ok, stream} = MockSpawnBackend.stream(h)

      collected = Enum.to_list(stream)
      assert Enum.all?(collected, &is_binary/1)
      assert length(collected) == 3
    end
  end
end
