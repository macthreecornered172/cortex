defmodule Cortex.Tool.Supervisor do
  @moduledoc """
  Task.Supervisor for sandboxed tool execution.

  This is a thin wrapper that provides the child spec for starting a
  `Task.Supervisor` named `Cortex.Tool.Supervisor`. The Executor uses this
  supervisor to spawn isolated task processes for tool execution, ensuring
  that tool crashes and timeouts never affect the calling agent process.

  The Scaffold Lead starts this supervisor in `Cortex.Application`'s
  supervision tree as:

      {Task.Supervisor, name: Cortex.Tool.Supervisor}

  This module exists so the child spec is defined in one place and tests
  can reference it by name.
  """

  @doc """
  Returns the child spec for the tool Task.Supervisor.

  ## Options

  - `:name` — the name to register the supervisor under (default: `Cortex.Tool.Supervisor`)

  Any additional options are passed through to `Task.Supervisor.start_link/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {Task.Supervisor, :start_link, [[name: name] ++ Keyword.delete(opts, :name)]},
      type: :supervisor
    }
  end
end
