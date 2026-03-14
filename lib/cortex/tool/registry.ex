defmodule Cortex.Tool.Registry do
  @moduledoc """
  Agent-backed tool name-to-module registry.

  Maintains an in-memory map of `tool_name => module` for tool lookup.
  Tools are registered by passing the implementing module; the registry
  calls `module.name()` to derive the lookup key.

  ## Semantics

  - **Last-write-wins** — registering a module whose `name()` matches an
    existing entry silently overwrites it. This enables hot-swapping tool
    implementations during development and testing.
  - **Behaviour validation** — `register/1` checks that the module exports
    all four `Cortex.Tool.Behaviour` callbacks before accepting it.
  - **In-memory only** — registrations are lost on process restart. The
    Application supervisor restarts this process, but tools must be
    re-registered.

  ## Usage

      Cortex.Tool.Registry.register(Cortex.Tool.Builtin.Shell)
      {:ok, module} = Cortex.Tool.Registry.lookup("shell")
      modules = Cortex.Tool.Registry.list()
  """

  use Agent

  require Logger

  @doc """
  Starts the tool registry Agent process.

  ## Options

  - `:name` — the name to register the Agent under (default: `Cortex.Tool.Registry`)
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc """
  Register a tool module in the registry.

  The module must implement `Cortex.Tool.Behaviour` (export `name/0`,
  `description/0`, `schema/0`, and `execute/1`). The tool's `name()` return
  value is used as the registry key.

  Returns `:ok` on success. Returns `{:error, :invalid_tool}` if the module
  does not implement the required callbacks.

  If a tool with the same name is already registered, it is silently replaced
  (last-write-wins) and a warning is logged.
  """
  @spec register(module(), GenServer.name()) :: :ok | {:error, :invalid_tool}
  def register(tool_module, registry \\ __MODULE__) do
    if valid_tool?(tool_module) do
      tool_name = tool_module.name()

      Agent.update(registry, fn tools ->
        if Map.has_key?(tools, tool_name) do
          Logger.warning(
            "Tool registry: overwriting tool #{inspect(tool_name)} " <>
              "(was #{inspect(Map.get(tools, tool_name))}, now #{inspect(tool_module)})"
          )
        end

        Map.put(tools, tool_name, tool_module)
      end)

      :ok
    else
      {:error, :invalid_tool}
    end
  end

  @doc """
  Look up a tool module by its name string.

  Returns `{:ok, module}` if found, or `{:error, :not_found}` if no tool
  is registered with the given name.
  """
  @spec lookup(String.t(), GenServer.name()) :: {:ok, module()} | {:error, :not_found}
  def lookup(name, registry \\ __MODULE__) do
    case Agent.get(registry, &Map.get(&1, name)) do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  @doc """
  List all registered tool modules.

  Returns a list of modules (not names). The order is not guaranteed.
  """
  @spec list(GenServer.name()) :: [module()]
  def list(registry \\ __MODULE__) do
    Agent.get(registry, &Map.values(&1))
  end

  # Validates that a module implements all four Cortex.Tool.Behaviour callbacks.
  # Uses Code.ensure_loaded/1 to guarantee the module's exports are available
  # for function_exported? checks (modules in test/support may not be loaded yet).
  @spec valid_tool?(module()) :: boolean()
  defp valid_tool?(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        function_exported?(module, :name, 0) and
          function_exported?(module, :description, 0) and
          function_exported?(module, :schema, 0) and
          function_exported?(module, :execute, 1)

      {:error, _} ->
        false
    end
  end
end
