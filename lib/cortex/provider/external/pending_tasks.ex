defmodule Cortex.Provider.External.PendingTasks do
  @moduledoc """
  GenServer that owns an ETS table mapping pending task IDs to waiting callers.

  When `Provider.External.run/3` dispatches a `TaskRequest` to a sidecar agent,
  it registers the task here. When the sidecar sends back a `TaskResult`,
  `resolve_task/3` delivers the result to the blocked caller and removes the entry.

  ## ETS Table

  The table `:cortex_pending_tasks` (configurable) is a `:set` with
  `read_concurrency: true`. Each entry is:

      {task_id, {caller_pid, caller_ref, dispatched_at, agent_id}}

  ## Caller Monitoring

  Each registered caller pid is monitored. If the caller dies before the task
  resolves, the entry is automatically removed to prevent ETS leaks.

  ## Supervision

  This GenServer is a child of `Cortex.Gateway.Supervisor`, started after
  `Gateway.Registry`. If it crashes, the supervisor restarts it with a fresh
  ETS table. In-flight tasks on the caller side will time out (acceptable for MVP).
  """

  use GenServer

  require Logger

  @default_table_name :cortex_pending_tasks

  # -- Public API --

  @doc """
  Starts the PendingTasks GenServer.

  ## Options

    - `:name` -- GenServer name, default `__MODULE__`
    - `:table_name` -- ETS table name, default `:cortex_pending_tasks`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a pending task in the ETS table.

  Inserts the task entry and monitors the caller pid so that the entry
  is automatically cleaned up if the caller dies.

  ## Parameters

    - `server` -- the PendingTasks GenServer reference
    - `task_id` -- unique task identifier (UUID v4 string)
    - `caller_pid` -- the process waiting for the result
    - `caller_ref` -- a unique reference the caller uses to match the result message
    - `agent_id` -- the ID of the agent the task was dispatched to
  """
  @spec register_task(GenServer.server(), String.t(), pid(), reference(), String.t()) :: :ok
  def register_task(server, task_id, caller_pid, caller_ref, agent_id) do
    GenServer.call(server, {:register, task_id, caller_pid, caller_ref, agent_id})
  end

  @doc """
  Resolves a pending task by delivering the result to the waiting caller.

  Looks up the task in ETS, sends `{:task_result, ref, result}` to the caller,
  removes the entry, and demonitors the caller pid.

  Returns `{:error, :not_found}` if the task ID is unknown or was already resolved.
  """
  @spec resolve_task(GenServer.server(), String.t(), map()) :: :ok | {:error, :not_found}
  def resolve_task(server, task_id, result) do
    GenServer.call(server, {:resolve, task_id, result})
  end

  @doc """
  Cancels a pending task without delivering a result.

  Removes the ETS entry and demonitors the caller pid. Returns `:ok`
  regardless of whether the task existed.
  """
  @spec cancel_task(GenServer.server(), String.t()) :: :ok
  def cancel_task(server, task_id) do
    GenServer.call(server, {:cancel, task_id})
  end

  @doc """
  Lists all currently pending tasks.

  Returns a list of maps with `:task_id`, `:agent_id`, and `:dispatched_at` fields.
  Useful for debugging and monitoring.
  """
  @spec list_pending(GenServer.server()) :: [
          %{task_id: String.t(), agent_id: String.t(), dispatched_at: integer()}
        ]
  def list_pending(server) do
    GenServer.call(server, :list_pending)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, @default_table_name)

    table =
      :ets.new(table_name, [
        :set,
        :protected,
        read_concurrency: true
      ])

    state = %{
      table: table,
      # monitor_ref => task_id
      monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, task_id, caller_pid, caller_ref, agent_id}, _from, state) do
    dispatched_at = System.monotonic_time(:millisecond)
    :ets.insert(state.table, {task_id, {caller_pid, caller_ref, dispatched_at, agent_id}})

    monitor_ref = Process.monitor(caller_pid)
    new_monitors = Map.put(state.monitors, monitor_ref, task_id)

    {:reply, :ok, %{state | monitors: new_monitors}}
  end

  def handle_call({:resolve, task_id, result}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, {caller_pid, caller_ref, _dispatched_at, _agent_id}}] ->
        send(caller_pid, {:task_result, caller_ref, result})
        :ets.delete(state.table, task_id)

        new_monitors = demonitor_for_task(state.monitors, task_id)
        {:reply, :ok, %{state | monitors: new_monitors}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:cancel, task_id}, _from, state) do
    :ets.delete(state.table, task_id)
    new_monitors = demonitor_for_task(state.monitors, task_id)
    {:reply, :ok, %{state | monitors: new_monitors}}
  end

  def handle_call(:list_pending, _from, state) do
    entries =
      :ets.tab2list(state.table)
      |> Enum.map(fn {task_id, {_pid, _ref, dispatched_at, agent_id}} ->
        %{task_id: task_id, agent_id: agent_id, dispatched_at: dispatched_at}
      end)

    {:reply, entries, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      task_id ->
        :ets.delete(state.table, task_id)
        new_monitors = Map.delete(state.monitors, ref)

        Logger.debug("PendingTasks: caller died, removed pending task #{task_id}")

        {:noreply, %{state | monitors: new_monitors}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  # Find and demonitor the monitor ref associated with a task_id
  @spec demonitor_for_task(%{reference() => String.t()}, String.t()) :: %{
          reference() => String.t()
        }
  defp demonitor_for_task(monitors, task_id) do
    case Enum.find(monitors, fn {_ref, tid} -> tid == task_id end) do
      {ref, _tid} ->
        Process.demonitor(ref, [:flush])
        Map.delete(monitors, ref)

      nil ->
        monitors
    end
  end
end
