defmodule Cortex.InternalAgent.SpawnConfigTest do
  use ExUnit.Case, async: true

  alias Cortex.InternalAgent.SpawnConfig

  @required_fields %{
    team_name: "test-agent",
    prompt: "do something",
    model: "haiku",
    max_turns: 1,
    permission_mode: "bypassPermissions",
    timeout_minutes: 2
  }

  describe "to_spawner_opts/1" do
    test "includes all required fields" do
      config = struct!(SpawnConfig, @required_fields)
      opts = SpawnConfig.to_spawner_opts(config)

      assert opts[:team_name] == "test-agent"
      assert opts[:prompt] == "do something"
      assert opts[:model] == "haiku"
      assert opts[:max_turns] == 1
      assert opts[:permission_mode] == "bypassPermissions"
      assert opts[:timeout_minutes] == 2
      assert opts[:command] == "claude"
    end

    test "omits nil optional fields" do
      config = struct!(SpawnConfig, @required_fields)
      opts = SpawnConfig.to_spawner_opts(config)

      refute Keyword.has_key?(opts, :log_path)
      refute Keyword.has_key?(opts, :cwd)
      refute Keyword.has_key?(opts, :on_token_update)
      refute Keyword.has_key?(opts, :on_activity)
      refute Keyword.has_key?(opts, :on_port_opened)
    end

    test "includes optional fields when set" do
      on_token = fn _name, _tokens -> :ok end
      on_act = fn _name, _activity -> :ok end
      on_port = fn _name, _pid -> :ok end

      config =
        struct!(SpawnConfig, %{
          @required_fields
          | team_name: "full-agent"
        })
        |> Map.merge(%{
          log_path: "/tmp/test.log",
          cwd: "/tmp",
          on_token_update: on_token,
          on_activity: on_act,
          on_port_opened: on_port
        })

      opts = SpawnConfig.to_spawner_opts(config)

      assert opts[:log_path] == "/tmp/test.log"
      assert opts[:cwd] == "/tmp"
      assert opts[:on_token_update] == on_token
      assert opts[:on_activity] == on_act
      assert opts[:on_port_opened] == on_port
    end

    test "respects custom command" do
      config = struct!(SpawnConfig, Map.put(@required_fields, :command, "/usr/local/bin/claude"))
      opts = SpawnConfig.to_spawner_opts(config)

      assert opts[:command] == "/usr/local/bin/claude"
    end
  end

  describe "struct enforcement" do
    test "raises on missing required fields" do
      assert_raise ArgumentError, fn ->
        struct!(SpawnConfig, %{team_name: "x"})
      end
    end
  end
end
