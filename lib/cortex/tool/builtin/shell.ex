defmodule Cortex.Tool.Builtin.Shell do
  @moduledoc """
  Built-in shell command execution tool.

  Implements `Cortex.Tool.Behaviour` to provide safe, sandboxed shell command
  execution with:

  - **Command allowlist** — only permitted commands can be executed (configurable
    via application config)
  - **Argument separation** — uses `System.cmd/3` with an argument list, never
    shell string interpolation, preventing injection attacks
  - **Output truncation** — caps output at a configurable maximum size (default 64KB)
    to prevent memory blowout from commands that produce unbounded output
  - **Exit code handling** — non-zero exit codes are returned as tagged errors

  ## Configuration

      # config/config.exs
      config :cortex, Cortex.Tool.Builtin.Shell,
        allowed_commands: ["ls", "cat", "echo", "wc", "head", "tail", "grep", "find", "pwd", "date"],
        max_output_bytes: 65_536

  ## Usage via Executor

      Cortex.Tool.Executor.run(Cortex.Tool.Builtin.Shell, %{
        "command" => "ls",
        "args" => ["-la", "/tmp"]
      })
      # => {:ok, "total 0\\ndrwxrwxrwt ..."}

  The shell tool itself does not enforce a timeout — it relies on the Executor's
  Task timeout for that. The `timeout_ms` arg is advisory and not currently used.
  """

  @behaviour Cortex.Tool.Behaviour

  @default_allowed_commands [
    "ls",
    "cat",
    "echo",
    "wc",
    "head",
    "tail",
    "grep",
    "find",
    "pwd",
    "date"
  ]

  @default_max_output_bytes 65_536

  @impl true
  @doc "Returns the tool name: `\"shell\"`."
  @spec name() :: String.t()
  def name, do: "shell"

  @impl true
  @doc "Returns a human-readable description of the shell tool."
  @spec description() :: String.t()
  def description,
    do: "Executes a shell command with argument list. Only allowlisted commands are permitted."

  @impl true
  @doc """
  Returns the JSON Schema for the shell tool's expected arguments.

  - `command` (required) — the command to execute (must be in the allowlist)
  - `args` (optional) — list of string arguments
  - `timeout_ms` (optional) — advisory timeout in milliseconds (not currently enforced)
  """
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "The command to execute"},
        "args" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Command arguments"
        },
        "timeout_ms" => %{
          "type" => "integer",
          "description" => "Advisory timeout in milliseconds",
          "default" => 10_000
        }
      },
      "required" => ["command"]
    }
  end

  @impl true
  @doc """
  Execute a shell command.

  ## Arguments

  - `"command"` — the command to execute (must be in the allowlist)
  - `"args"` — list of string arguments (default: `[]`)
  - `"timeout_ms"` — advisory timeout, not currently enforced (default: `10_000`)

  ## Returns

  - `{:ok, stdout}` — command succeeded (exit code 0), stdout truncated to max output size
  - `{:error, {:disallowed_command, command}}` — command not in the allowlist
  - `{:error, {:exit_code, code, output}}` — command exited with non-zero code
  - `{:error, {:execution_error, reason}}` — system-level error (command not found, etc.)
  """
  @spec execute(map()) :: {:ok, String.t()} | {:error, term()}
  def execute(%{"command" => command} = args) do
    cmd_args = Map.get(args, "args", [])

    if allowed_command?(command) do
      execute_command(command, cmd_args)
    else
      {:error, {:disallowed_command, command}}
    end
  end

  def execute(_args), do: {:error, :missing_command}

  # Execute the command via System.cmd and handle the result.
  @spec execute_command(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  defp execute_command(command, args) do
    try do
      case System.cmd(command, args, stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, truncate_output(output)}

        {output, exit_code} ->
          {:error, {:exit_code, exit_code, truncate_output(output)}}
      end
    rescue
      e in ErlangError ->
        {:error, {:execution_error, Exception.message(e)}}
    end
  end

  # Truncate output to the configured max size.
  @spec truncate_output(String.t()) :: String.t()
  defp truncate_output(output) do
    max_bytes = max_output_bytes()

    if byte_size(output) > max_bytes do
      binary_part(output, 0, max_bytes)
    else
      output
    end
  end

  # Check if a command is in the allowlist.
  @spec allowed_command?(String.t()) :: boolean()
  defp allowed_command?(command) do
    command in allowed_commands()
  end

  @doc false
  @spec allowed_commands() :: [String.t()]
  def allowed_commands do
    Application.get_env(:cortex, __MODULE__, [])
    |> Keyword.get(:allowed_commands, @default_allowed_commands)
  end

  @doc false
  @spec max_output_bytes() :: non_neg_integer()
  def max_output_bytes do
    Application.get_env(:cortex, __MODULE__, [])
    |> Keyword.get(:max_output_bytes, @default_max_output_bytes)
  end
end
