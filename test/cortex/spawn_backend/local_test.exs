defmodule Cortex.SpawnBackend.LocalTest do
  use ExUnit.Case, async: true

  alias Cortex.SpawnBackend.Local

  @moduletag :tmp_dir

  # -- Helpers ---------------------------------------------------------------

  defp write_mock_script(tmp_dir, name, body) do
    path = Path.join(tmp_dir, name)
    File.write!(path, "#!/bin/bash\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp spawn_handle(_tmp_dir, script_path, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)

    Local.spawn(
      command: script_path,
      args: [],
      timeout_ms: timeout_ms
    )
  end

  # Simple collector that gathers all data chunks and the final exit event
  defp data_collector({:data, data}, acc) do
    {:cont, %{acc | data: acc.data <> data}}
  end

  defp data_collector({:exit, code}, acc) do
    {:halt, %{acc | exit_code: code}}
  end

  defp data_collector(:timeout, acc) do
    {:halt, %{acc | timeout: true}}
  end

  defp data_collector({:port_died, collected}, acc) do
    {:halt, %{acc | port_died: true, data: collected}}
  end

  defp initial_acc do
    %{data: "", exit_code: nil, timeout: false, port_died: false}
  end

  # -- Tests -----------------------------------------------------------------

  describe "spawn/1" do
    test "returns an ok tuple with a handle", %{tmp_dir: tmp_dir} do
      script = write_mock_script(tmp_dir, "echo.sh", "echo hello")

      assert {:ok, handle} = spawn_handle(tmp_dir, script)
      assert %Local.Handle{port: port, timer_ref: timer_ref} = handle
      assert is_port(port)
      assert is_reference(timer_ref)
    end

    test "captures os_pid in handle", %{tmp_dir: tmp_dir} do
      script = write_mock_script(tmp_dir, "pid.sh", "echo $$; sleep 1")

      assert {:ok, handle} = spawn_handle(tmp_dir, script)
      assert is_integer(handle.os_pid) or is_nil(handle.os_pid)

      # Clean up
      Local.stop(handle)
    end

    test "resolves command via System.find_executable fallback", %{tmp_dir: tmp_dir} do
      script = write_mock_script(tmp_dir, "resolve.sh", "echo resolved")

      # Pass the full path — should still work
      assert {:ok, handle} = spawn_handle(tmp_dir, script)
      result = Local.collect(handle, initial_acc(), &data_collector/2)
      assert result.exit_code == 0
      assert result.data =~ "resolved"
    end
  end

  describe "collect/3" do
    test "collects data and exit event on success", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "success.sh", """
        echo "line one"
        echo "line two"
        """)

      {:ok, handle} = spawn_handle(tmp_dir, script)
      result = Local.collect(handle, initial_acc(), &data_collector/2)

      assert result.exit_code == 0
      assert result.data =~ "line one"
      assert result.data =~ "line two"
    end

    test "reports non-zero exit code", %{tmp_dir: tmp_dir} do
      script = write_mock_script(tmp_dir, "fail.sh", "exit 42")

      {:ok, handle} = spawn_handle(tmp_dir, script)
      result = Local.collect(handle, initial_acc(), &data_collector/2)

      assert result.exit_code == 42
    end

    test "handler can halt early", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "lots.sh", """
        for i in $(seq 1 100); do echo "line $i"; done
        sleep 10
        """)

      {:ok, handle} = spawn_handle(tmp_dir, script)

      halt_after_first = fn
        {:data, data}, acc ->
          new_data = acc.data <> data

          if String.contains?(new_data, "line 1") do
            {:halt, %{acc | data: new_data}}
          else
            {:cont, %{acc | data: new_data}}
          end

        event, acc ->
          data_collector(event, acc)
      end

      result = Local.collect(handle, initial_acc(), halt_after_first)

      assert result.data =~ "line 1"
      # Handler halted, so no exit_code
      assert result.exit_code == nil

      # Clean up
      Local.stop(handle)
    end

    test "fires timeout event and kills port", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "hang.sh", """
        echo "started"
        sleep 300
        """)

      {:ok, handle} = spawn_handle(tmp_dir, script, timeout_ms: 1_000)

      start = System.monotonic_time(:millisecond)
      result = Local.collect(handle, initial_acc(), &data_collector/2)
      elapsed = System.monotonic_time(:millisecond) - start

      assert result.timeout == true
      assert elapsed < 5_000
    end

    test "accumulator is threaded through all events", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "count.sh", """
        echo "a"
        echo "b"
        echo "c"
        """)

      {:ok, handle} = spawn_handle(tmp_dir, script)

      counter = fn
        {:data, _data}, count -> {:cont, count + 1}
        {:exit, _code}, count -> {:halt, count}
        _, count -> {:halt, count}
      end

      # At least 1 data event (lines may arrive in a single chunk)
      final_count = Local.collect(handle, 0, counter)
      assert final_count >= 1
    end
  end

  describe "stop/1" do
    test "stops a port and returns ok", %{tmp_dir: tmp_dir} do
      script = write_mock_script(tmp_dir, "long.sh", "sleep 300")

      {:ok, handle} = spawn_handle(tmp_dir, script)
      assert :ok = Local.stop(handle)
    end

    test "is idempotent — safe to call twice", %{tmp_dir: tmp_dir} do
      script = write_mock_script(tmp_dir, "idempotent.sh", "sleep 300")

      {:ok, handle} = spawn_handle(tmp_dir, script)
      assert :ok = Local.stop(handle)
      assert :ok = Local.stop(handle)
    end
  end

  describe "status/1" do
    test "returns :running for an active port", %{tmp_dir: tmp_dir} do
      script = write_mock_script(tmp_dir, "active.sh", "sleep 300")

      {:ok, handle} = spawn_handle(tmp_dir, script)
      assert Local.status(handle) == :running

      Local.stop(handle)
    end

    test "returns :done for a completed port", %{tmp_dir: tmp_dir} do
      script = write_mock_script(tmp_dir, "quick.sh", "echo done")

      {:ok, handle} = spawn_handle(tmp_dir, script)
      # Wait for the process to finish
      Local.collect(handle, initial_acc(), &data_collector/2)

      assert Local.status(handle) == :done
    end
  end

  describe "environment stripping" do
    test "CLAUDECODE env var is not passed to child process", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "env.sh", """
        echo "CLAUDECODE=${CLAUDECODE:-unset}"
        echo "CLAUDE_CODE_ENTRYPOINT=${CLAUDE_CODE_ENTRYPOINT:-unset}"
        """)

      # Set the env vars in the current process
      System.put_env("CLAUDECODE", "test_value")
      System.put_env("CLAUDE_CODE_ENTRYPOINT", "test_entry")

      {:ok, handle} = spawn_handle(tmp_dir, script)
      result = Local.collect(handle, initial_acc(), &data_collector/2)

      assert result.data =~ "CLAUDECODE=unset"
      assert result.data =~ "CLAUDE_CODE_ENTRYPOINT=unset"
    after
      System.delete_env("CLAUDECODE")
      System.delete_env("CLAUDE_CODE_ENTRYPOINT")
    end
  end

  describe "stream/1 behaviour callback" do
    test "returns an ok tuple with a lazy stream", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "stream.sh", """
        echo "hello"
        echo "world"
        """)

      {:ok, handle} = spawn_handle(tmp_dir, script)
      assert {:ok, stream} = Local.stream(handle)
      assert is_function(stream) or is_struct(stream, Stream)

      events = Enum.to_list(stream)
      data_events = Enum.filter(events, fn {tag, _} -> tag == :data end)
      assert length(data_events) >= 1
    end
  end

  describe "behaviour compliance" do
    test "SpawnBackend.Local implements @behaviour Cortex.SpawnBackend" do
      behaviours =
        Local.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Cortex.SpawnBackend in behaviours
    end
  end
end
