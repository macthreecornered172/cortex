defmodule Cortex.Provider.CLITest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.TeamResult
  alias Cortex.Provider.CLI

  @moduletag :tmp_dir

  # -- Helpers ---------------------------------------------------------------

  defp write_mock_script(tmp_dir, name, body) do
    path = Path.join(tmp_dir, name)
    File.write!(path, "#!/bin/bash\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp base_opts(tmp_dir, script_path) do
    [
      team_name: "test-team",
      prompt: "Do the thing",
      command: script_path,
      timeout_minutes: 1,
      log_path: Path.join(tmp_dir, "test.log")
    ]
  end

  # -- run/1 Tests -----------------------------------------------------------

  describe "run/1 with valid NDJSON result" do
    test "parses a successful result from mock script", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "success.sh", """
        echo '{"type":"system","subtype":"init","session_id":"test-sess-001"}'
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Working..."}]}}'
        echo '{"type":"result","subtype":"success","result":"All tasks completed","cost_usd":0.45,"num_turns":5,"duration_ms":30000,"session_id":"test-sess-001"}'
        """)

      assert {:ok, %TeamResult{} = result} = CLI.run(base_opts(tmp_dir, script))

      assert result.team == "test-team"
      assert result.status == :success
      assert result.result == "All tasks completed"
      assert result.cost_usd == 0.45
      assert result.num_turns == 5
      assert result.duration_ms == 30_000
      assert result.session_id == "test-sess-001"
    end

    test "captures session_id from system init line", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "session.sh", """
        echo '{"type":"system","subtype":"init","session_id":"unique-session-42"}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.10,"num_turns":1,"duration_ms":5000}'
        """)

      assert {:ok, %TeamResult{session_id: "unique-session-42"}} =
               CLI.run(base_opts(tmp_dir, script))
    end

    test "falls back to session_id from result line when no init line", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "no_init.sh", """
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.10,"num_turns":1,"duration_ms":5000,"session_id":"from-result"}'
        """)

      assert {:ok, %TeamResult{session_id: "from-result"}} =
               CLI.run(base_opts(tmp_dir, script))
    end

    test "handles error subtype in result line", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "error_result.sh", """
        echo '{"type":"system","subtype":"init","session_id":"err-sess"}'
        echo '{"type":"result","subtype":"error","result":"Tool execution failed","cost_usd":0.05,"num_turns":2,"duration_ms":10000}'
        """)

      assert {:ok, %TeamResult{status: :error, result: "Tool execution failed"}} =
               CLI.run(base_opts(tmp_dir, script))
    end

    test "detects rate_limited status from result text", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "rate_limit.sh", """
        echo '{"type":"result","subtype":"success","result":"rate_limit_error: too many requests","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      assert {:ok, %TeamResult{status: :rate_limited}} =
               CLI.run(base_opts(tmp_dir, script))
    end

    test "handles error_max_turns subtype as success", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "max_turns.sh", """
        echo '{"type":"result","subtype":"error_max_turns","result":"Ran out of turns","cost_usd":0.50,"num_turns":200,"duration_ms":60000}'
        """)

      assert {:ok, %TeamResult{status: :success}} =
               CLI.run(base_opts(tmp_dir, script))
    end
  end

  describe "run/1 with non-zero exit code" do
    test "returns error tuple with exit code", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "fail.sh", """
        echo '{"type":"system","subtype":"init","session_id":"fail-sess"}'
        exit 1
        """)

      assert {:error, {:exit_code, 1, _output}} = CLI.run(base_opts(tmp_dir, script))
    end

    test "returns specific exit code value", %{tmp_dir: tmp_dir} do
      script = write_mock_script(tmp_dir, "fail42.sh", "exit 42")

      assert {:error, {:exit_code, 42, _output}} = CLI.run(base_opts(tmp_dir, script))
    end
  end

  describe "run/1 with timeout" do
    test "kills the process and returns timeout status", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "hang.sh", """
        echo '{"type":"system","subtype":"init","session_id":"hang-sess"}'
        sleep 300
        """)

      opts =
        tmp_dir
        |> base_opts(script)
        |> Keyword.put(:timeout_minutes, 1 / 60)

      start = System.monotonic_time(:millisecond)
      result = CLI.run(opts)
      elapsed = System.monotonic_time(:millisecond) - start

      assert {:ok, %TeamResult{status: :timeout, team: "test-team"}} = result
      assert elapsed < 5_000
    end
  end

  describe "run/1 log file writing" do
    test "writes raw output to log_path when set", %{tmp_dir: tmp_dir} do
      log_path = Path.join(tmp_dir, "team.log")

      script =
        write_mock_script(tmp_dir, "log_test.sh", """
        echo '{"type":"system","subtype":"init","session_id":"log-sess"}'
        echo '{"type":"result","subtype":"success","result":"Logged","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      opts = [
        team_name: "log-team",
        prompt: "Log this",
        command: script,
        timeout_minutes: 1,
        log_path: log_path
      ]

      assert {:ok, %TeamResult{}} = CLI.run(opts)
      assert File.exists?(log_path)

      contents = File.read!(log_path)
      assert contents =~ "system"
      assert contents =~ "result"
      assert contents =~ "log-sess"
    end

    test "does not create log file when log_path is nil", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "no_log.sh", """
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      opts = [
        team_name: "no-log-team",
        prompt: "No log",
        command: script,
        timeout_minutes: 1
      ]

      assert {:ok, %TeamResult{}} = CLI.run(opts)

      log_files =
        tmp_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".log"))

      assert log_files == []
    end

    test "creates parent directories for log_path", %{tmp_dir: tmp_dir} do
      log_path = Path.join([tmp_dir, "nested", "dirs", "team.log"])

      script =
        write_mock_script(tmp_dir, "nested_log.sh", """
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      opts = [
        team_name: "nested-team",
        prompt: "Nested log",
        command: script,
        timeout_minutes: 1,
        log_path: log_path
      ]

      assert {:ok, %TeamResult{}} = CLI.run(opts)
      assert File.exists?(log_path)
    end
  end

  describe "run/1 with missing result line" do
    test "returns error when process exits without result line", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "no_result.sh", """
        echo '{"type":"system","subtype":"init","session_id":"no-result-sess"}'
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Working"}]}}'
        """)

      assert {:error, :no_result_line} = CLI.run(base_opts(tmp_dir, script))
    end
  end

  describe "run/1 option requirements" do
    test "requires team_name" do
      assert_raise KeyError, ~r/:team_name/, fn ->
        CLI.run(prompt: "test")
      end
    end

    test "requires prompt" do
      assert_raise KeyError, ~r/:prompt/, fn ->
        CLI.run(team_name: "test")
      end
    end
  end

  describe "run/1 live token streaming" do
    test "calls on_token_update callback with accumulated usage", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "tokens.sh", """
        echo '{"type":"system","subtype":"init","session_id":"tok-sess"}'
        echo '{"type":"message_start","message":{"usage":{"input_tokens":100,"output_tokens":0}}}'
        echo '{"type":"message_delta","usage":{"output_tokens":50}}'
        echo '{"type":"message_start","message":{"usage":{"input_tokens":200,"output_tokens":0}}}'
        echo '{"type":"message_delta","usage":{"output_tokens":75}}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.10,"num_turns":2,"duration_ms":5000,"usage":{"input_tokens":300,"output_tokens":125}}'
        """)

      test_pid = self()

      on_token_update = fn team_name, tokens ->
        send(test_pid, {:token_update, team_name, tokens})
      end

      opts = base_opts(tmp_dir, script) ++ [on_token_update: on_token_update]

      assert {:ok, %TeamResult{}} = CLI.run(opts)

      assert_received {:token_update, "test-team", tokens}
      assert tokens.input_tokens > 0 or tokens.output_tokens > 0
    end

    test "does not crash when on_token_update is nil", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "no_cb.sh", """
        echo '{"type":"message_start","message":{"usage":{"input_tokens":100,"output_tokens":50}}}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      assert {:ok, %TeamResult{}} = CLI.run(base_opts(tmp_dir, script))
    end
  end

  describe "run/1 activity callbacks" do
    test "calls on_activity callback for tool_use in assistant message", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "activity.sh", """
        echo '{"type":"system","subtype":"init","session_id":"act-sess"}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hello"}}]}}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      test_pid = self()

      on_activity = fn team_name, activity ->
        send(test_pid, {:activity, team_name, activity})
      end

      opts = base_opts(tmp_dir, script) ++ [on_activity: on_activity]

      assert {:ok, %TeamResult{}} = CLI.run(opts)

      # Should receive session_started and tool_use activities
      assert_received {:activity, "test-team", %{type: :session_started}}
      assert_received {:activity, "test-team", %{type: :tool_use, tools: ["Bash"]}}
    end

    test "does not crash when on_activity callback raises", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "raise.sh", """
        echo '{"type":"system","subtype":"init","session_id":"raise-sess"}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/test.txt"}}]}}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      on_activity = fn _team_name, _activity ->
        raise "boom"
      end

      opts = base_opts(tmp_dir, script) ++ [on_activity: on_activity]

      # Should not crash despite the raising callback
      assert {:ok, %TeamResult{status: :success}} = CLI.run(opts)
    end
  end

  describe "run/1 on_port_opened callback" do
    test "invokes callback with team name and os_pid", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "port_cb.sh", """
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      test_pid = self()

      on_port_opened = fn team_name, os_pid ->
        send(test_pid, {:port_opened, team_name, os_pid})
      end

      opts = base_opts(tmp_dir, script) ++ [on_port_opened: on_port_opened]

      assert {:ok, %TeamResult{}} = CLI.run(opts)

      assert_received {:port_opened, "test-team", os_pid}
      assert is_integer(os_pid) or is_nil(os_pid)
    end
  end

  describe "run/1 with interleaved non-JSON lines" do
    test "skips non-JSON lines gracefully", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "noisy.sh", """
        echo 'WARNING: something happened'
        echo '{"type":"system","subtype":"init","session_id":"noisy-sess"}'
        echo 'Another non-JSON line'
        echo '{"type":"result","subtype":"success","result":"Done despite noise","cost_usd":0.02,"num_turns":1,"duration_ms":2000}'
        """)

      assert {:ok, %TeamResult{status: :success, result: "Done despite noise"}} =
               CLI.run(base_opts(tmp_dir, script))
    end
  end

  describe "resume/1" do
    test "resumes a session with session_id", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "resume.sh", """
        echo '{"type":"system","subtype":"init","session_id":"resumed-sess"}'
        echo '{"type":"result","subtype":"success","result":"Resumed work","cost_usd":0.10,"num_turns":3,"duration_ms":5000}'
        """)

      opts = [
        team_name: "resume-team",
        session_id: "original-sess-123",
        command: script,
        timeout_minutes: 1,
        log_path: Path.join(tmp_dir, "resume.log")
      ]

      assert {:ok, %TeamResult{status: :success, result: "Resumed work"}} = CLI.resume(opts)
    end

    test "requires session_id" do
      assert_raise KeyError, ~r/:session_id/, fn ->
        CLI.resume(team_name: "test", prompt: "continue")
      end
    end
  end

  # -- Provider Behaviour Lifecycle Tests --------------------------------------

  describe "start/1" do
    test "returns ok tuple with handle from map config" do
      assert {:ok, handle} = CLI.start(%{command: "echo", cwd: "/tmp"})
      assert handle.command == "echo"
      assert handle.cwd == "/tmp"
    end

    test "returns ok tuple with handle from keyword config" do
      assert {:ok, handle} = CLI.start(command: "echo", cwd: "/tmp")
      assert handle.command == "echo"
      assert handle.cwd == "/tmp"
    end

    test "uses defaults when config keys are missing" do
      assert {:ok, handle} = CLI.start(%{})
      assert handle.command == "claude"
      assert handle.cwd == nil
    end
  end

  describe "run/3 behaviour callback" do
    test "executes prompt via handle and returns TeamResult", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "run3.sh", """
        echo '{"type":"system","subtype":"init","session_id":"run3-sess"}'
        echo '{"type":"result","subtype":"success","result":"Via run/3","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      {:ok, handle} = CLI.start(%{command: script})

      assert {:ok, %TeamResult{status: :success, result: "Via run/3"}} =
               CLI.run(handle, "test prompt", team_name: "run3-team", timeout_minutes: 1)
    end

    test "supports session_id option for resume via run/3", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "run3_resume.sh", """
        echo '{"type":"system","subtype":"init","session_id":"run3-resume-sess"}'
        echo '{"type":"result","subtype":"success","result":"Resumed via run/3","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      {:ok, handle} = CLI.start(%{command: script})

      assert {:ok, %TeamResult{status: :success}} =
               CLI.run(handle, "continue",
                 team_name: "run3-team",
                 session_id: "old-sess",
                 timeout_minutes: 1
               )
    end
  end

  describe "resume/2 behaviour callback" do
    test "resumes session via handle", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "resume2.sh", """
        echo '{"type":"system","subtype":"init","session_id":"resume2-sess"}'
        echo '{"type":"result","subtype":"success","result":"Resumed via resume/2","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      {:ok, handle} = CLI.start(%{command: script})

      assert {:ok, %TeamResult{status: :success}} =
               CLI.resume(handle,
                 team_name: "resume2-team",
                 session_id: "old-sess",
                 timeout_minutes: 1
               )
    end
  end

  describe "stop/1" do
    test "returns :ok (no-op for CLI)" do
      {:ok, handle} = CLI.start(%{command: "echo"})
      assert :ok = CLI.stop(handle)
    end

    test "is idempotent" do
      {:ok, handle} = CLI.start(%{command: "echo"})
      assert :ok = CLI.stop(handle)
      assert :ok = CLI.stop(handle)
    end
  end

  describe "behaviour compliance" do
    test "Provider.CLI implements @behaviour Cortex.Provider" do
      behaviours =
        CLI.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Cortex.Provider in behaviours
    end
  end
end
