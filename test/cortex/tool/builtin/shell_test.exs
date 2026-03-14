defmodule Cortex.Tool.Builtin.ShellTest do
  use ExUnit.Case, async: true

  alias Cortex.Tool.Builtin.Shell

  describe "behaviour compliance" do
    test "name/0 returns 'shell'" do
      assert Shell.name() == "shell"
    end

    test "description/0 returns a string" do
      assert is_binary(Shell.description())
    end

    test "schema/0 returns a valid JSON Schema map" do
      schema = Shell.schema()
      assert schema["type"] == "object"
      assert "command" in schema["required"]
      assert is_map(schema["properties"]["command"])
    end

    test "exports all behaviour callbacks" do
      assert function_exported?(Shell, :name, 0)
      assert function_exported?(Shell, :description, 0)
      assert function_exported?(Shell, :schema, 0)
      assert function_exported?(Shell, :execute, 1)
    end
  end

  describe "execute/1 with allowed commands" do
    test "echo command returns stdout" do
      assert {:ok, output} = Shell.execute(%{"command" => "echo", "args" => ["hello world"]})
      assert String.trim(output) == "hello world"
    end

    test "pwd command returns current directory" do
      assert {:ok, output} = Shell.execute(%{"command" => "pwd"})
      assert String.trim(output) != ""
    end

    test "date command returns output" do
      assert {:ok, output} = Shell.execute(%{"command" => "date"})
      assert String.trim(output) != ""
    end

    test "empty args list works" do
      assert {:ok, output} = Shell.execute(%{"command" => "pwd", "args" => []})
      assert String.trim(output) != ""
    end

    test "args default to empty list when not provided" do
      assert {:ok, _output} = Shell.execute(%{"command" => "pwd"})
    end
  end

  describe "execute/1 with disallowed commands" do
    test "returns {:error, {:disallowed_command, _}} for rm" do
      assert {:error, {:disallowed_command, "rm"}} =
               Shell.execute(%{"command" => "rm", "args" => ["-rf", "/"]})
    end

    test "returns {:error, {:disallowed_command, _}} for curl" do
      assert {:error, {:disallowed_command, "curl"}} =
               Shell.execute(%{"command" => "curl", "args" => ["http://example.com"]})
    end

    test "returns {:error, {:disallowed_command, _}} for arbitrary command" do
      assert {:error, {:disallowed_command, "malicious_binary"}} =
               Shell.execute(%{"command" => "malicious_binary"})
    end
  end

  describe "execute/1 with non-zero exit code" do
    test "returns error with exit code and output" do
      # grep with no match returns exit code 1
      result =
        Shell.execute(%{"command" => "grep", "args" => ["nonexistent_pattern_xyz", "/dev/null"]})

      assert {:error, {:exit_code, 1, _output}} = result
    end

    test "ls on nonexistent path returns error with exit code" do
      result =
        Shell.execute(%{
          "command" => "ls",
          "args" => ["/this/path/definitely/does/not/exist/abc123"]
        })

      assert {:error, {:exit_code, _code, _output}} = result
    end
  end

  describe "execute/1 with missing command" do
    test "returns {:error, :missing_command} when no command key" do
      assert {:error, :missing_command} = Shell.execute(%{})
    end
  end

  describe "output truncation" do
    test "output exceeding max_output_bytes is truncated" do
      # Generate output larger than default 64KB
      # Each echo line is about 100 chars, so 1000 repetitions should exceed 64KB
      # Use a more reliable approach: generate lots of output via wc counting a big echo
      # Actually, let's just test the truncation logic by using a small max via config

      # Temporarily set a small max output
      original = Application.get_env(:cortex, Cortex.Tool.Builtin.Shell)
      Application.put_env(:cortex, Cortex.Tool.Builtin.Shell, max_output_bytes: 10)

      try do
        {:ok, output} =
          Shell.execute(%{
            "command" => "echo",
            "args" => ["this is a long string that exceeds 10 bytes"]
          })

        assert byte_size(output) == 10
      after
        # Restore original config
        if original do
          Application.put_env(:cortex, Cortex.Tool.Builtin.Shell, original)
        else
          Application.delete_env(:cortex, Cortex.Tool.Builtin.Shell)
        end
      end
    end

    test "output within max_output_bytes is not truncated" do
      {:ok, output} = Shell.execute(%{"command" => "echo", "args" => ["short"]})
      # "short\n" is 6 bytes, well within 64KB
      assert output == "short\n"
    end
  end
end
