defmodule Cortex.Tool.Behaviour do
  @moduledoc """
  Behaviour contract for Cortex tools.

  Any module implementing this behaviour can be registered in the Tool Registry
  and executed by the Tool Executor. The contract defines four callbacks:

  - `name/0` — unique string identifier used for registry lookup
  - `description/0` — human-readable description for agent prompt injection
  - `schema/0` — JSON Schema map describing expected arguments
  - `execute/1` — takes an args map, returns `{:ok, result}` or `{:error, reason}`

  ## Example

      defmodule MyTool do
        @behaviour Cortex.Tool.Behaviour

        @impl true
        def name, do: "my_tool"

        @impl true
        def description, do: "Does something useful"

        @impl true
        def schema do
          %{
            "type" => "object",
            "properties" => %{
              "input" => %{"type" => "string"}
            },
            "required" => ["input"]
          }
        end

        @impl true
        def execute(%{"input" => input}) do
          {:ok, String.upcase(input)}
        end
      end
  """

  @doc "Unique string identifier for this tool, used as the registry key."
  @callback name() :: String.t()

  @doc "Human-readable description of what this tool does."
  @callback description() :: String.t()

  @doc "JSON Schema map describing the expected arguments for `execute/1`."
  @callback schema() :: map()

  @doc """
  Execute the tool with the given arguments.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  This function runs inside a sandboxed Task process managed by the Executor,
  so crashes here will not propagate to the calling agent.
  """
  @callback execute(args :: map()) :: {:ok, term()} | {:error, term()}
end
