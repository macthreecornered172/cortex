defmodule Cortex.Provider.External do
  @moduledoc """
  Provider implementation that dispatches work to sidecar-connected agents via the Gateway.

  Implements the `Cortex.Provider` behaviour. Instead of spawning a local `claude -p`
  process, this provider finds a registered agent by name in `Gateway.Registry`,
  pushes a `TaskRequest` to the agent's sidecar via gRPC or WebSocket, and blocks
  until a `TaskResult` arrives or the timeout expires.

  ## Lifecycle

      {:ok, handle} = Provider.External.start(registry: MyRegistry)
      {:ok, result} = Provider.External.run(handle, "Build the API", team_name: "backend")
      :ok = Provider.External.stop(handle)

  ## Dispatch Flow

  1. Generate a unique `task_id` (UUID v4)
  2. Find the target agent by name in `Gateway.Registry`
  3. Register the pending task in `PendingTasks` (ETS-backed)
  4. Push the `TaskRequest` via `TaskPush.push/3`
  5. Update agent status to `:working`
  6. Block on `receive` with timeout waiting for the result
  7. Convert the `TaskResult` map to a `TeamResult` struct
  8. Emit telemetry events

  ## Configuration

    - `:registry` -- `GenServer.server()` for `Gateway.Registry` (default: `Gateway.Registry`)
    - `:timeout_ms` -- default timeout in milliseconds (default: 1,800,000 = 30 min)
    - `:pending_tasks` -- `GenServer.server()` for `PendingTasks` (default: `PendingTasks`)
    - `:push_fn` -- function `(transport, pid, task_request) -> :ok | {:error, term()}`
      for test injection (default: `&TaskPush.push/3`)
  """

  @behaviour Cortex.Provider

  alias Cortex.Gateway.Registry
  alias Cortex.Orchestration.TeamResult
  alias Cortex.Provider.External.PendingTasks
  alias Cortex.Provider.External.TaskPush
  alias Cortex.Telemetry

  require Logger

  @default_timeout_ms 1_800_000

  # -- Provider Behaviour Callbacks --

  @doc """
  Initializes the external provider handle.

  Validates that the Gateway Registry is running and returns a handle map
  containing the registry reference, timeout, pending tasks server, and push function.

  ## Config Keys

    - `:registry` -- `GenServer.server()`, default `Gateway.Registry`
    - `:timeout_ms` -- integer, default 1,800,000 (30 min)
    - `:pending_tasks` -- `GenServer.server()`, default `PendingTasks`
    - `:push_fn` -- push function for test injection

  Returns `{:error, :registry_not_available}` if the Registry process is not running.
  """
  @impl Cortex.Provider
  @spec start(Cortex.Provider.config()) :: {:ok, Cortex.Provider.handle()} | {:error, term()}
  def start(config) when is_map(config) do
    start(Map.to_list(config))
  end

  def start(config) when is_list(config) do
    registry = Keyword.get(config, :registry, Registry)
    timeout_ms = Keyword.get(config, :timeout_ms, @default_timeout_ms)
    pending_tasks = Keyword.get(config, :pending_tasks, PendingTasks)
    push_fn = Keyword.get(config, :push_fn, &default_push/3)

    if process_alive?(registry) do
      {:ok,
       %{
         registry: registry,
         timeout_ms: timeout_ms,
         pending_tasks: pending_tasks,
         push_fn: push_fn
       }}
    else
      {:error, :registry_not_available}
    end
  end

  @doc """
  Dispatches a prompt to a sidecar-connected agent and blocks until the result arrives.

  Finds the target agent by `:team_name` in the Registry, pushes a `TaskRequest`,
  and blocks the calling process until a `TaskResult` is delivered via
  `PendingTasks.resolve_task/3` or the timeout expires.

  ## Run Options

    - `:team_name` -- required, string matching the agent's registered name
    - `:timeout_ms` -- optional, overrides the handle default

  ## Return Values

    - `{:ok, %TeamResult{}}` -- task completed successfully or with error status
    - `{:error, :agent_not_found}` -- no agent with matching name in Registry
    - `{:error, :push_failed}` -- could not send TaskRequest to agent's transport
    - `{:error, :timeout}` -- no TaskResult received within timeout
  """
  @impl Cortex.Provider
  @spec run(Cortex.Provider.handle(), String.t(), Cortex.Provider.run_opts()) ::
          {:ok, TeamResult.t()} | {:error, term()}
  def run(handle, prompt, opts) when is_map(handle) and is_list(opts) do
    team_name = Keyword.fetch!(opts, :team_name)
    timeout_ms = Keyword.get(opts, :timeout_ms, handle.timeout_ms)

    case find_agent_by_name(handle.registry, team_name) do
      {:ok, agent} ->
        dispatch_and_wait(handle, agent, prompt, team_name, timeout_ms)

      {:error, :agent_not_found} ->
        {:error, :agent_not_found}
    end
  end

  @doc """
  Releases external provider resources.

  No-op for the external provider since it is stateless between runs.
  """
  @impl Cortex.Provider
  @spec stop(Cortex.Provider.handle()) :: :ok
  def stop(_handle), do: :ok

  # -- Private --

  @spec find_agent_by_name(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, :agent_not_found}
  defp find_agent_by_name(registry, team_name) do
    agents = Registry.list(registry)

    case Enum.find(agents, fn agent -> agent.name == team_name end) do
      nil -> {:error, :agent_not_found}
      agent -> {:ok, agent}
    end
  end

  @spec dispatch_and_wait(map(), map(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, TeamResult.t()} | {:error, term()}
  defp dispatch_and_wait(handle, agent, prompt, team_name, timeout_ms) do
    task_id = Ecto.UUID.generate()
    caller_ref = make_ref()

    # Register pending task before pushing to avoid race condition
    :ok =
      PendingTasks.register_task(
        handle.pending_tasks,
        task_id,
        self(),
        caller_ref,
        agent.id
      )

    task_request = build_task_request(task_id, prompt, team_name, timeout_ms)

    case push_task(handle, agent, task_request) do
      {:ok, :sent} ->
        emit_dispatched(task_id, agent.id)
        update_agent_status(agent.id, :working)
        wait_for_result(handle, task_id, caller_ref, team_name, agent.id, timeout_ms)

      {:error, _reason} ->
        PendingTasks.cancel_task(handle.pending_tasks, task_id)
        {:error, :push_failed}
    end
  end

  @spec push_task(map(), map(), map()) :: {:ok, :sent} | {:error, term()}
  defp push_task(handle, agent, task_request) do
    case Registry.get_push_pid(handle.registry, agent.id) do
      {:ok, {transport, pid}} ->
        handle.push_fn.(transport, pid, task_request)

      {:error, :not_found} ->
        {:error, :agent_not_found}
    end
  end

  @spec wait_for_result(map(), String.t(), reference(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, TeamResult.t()} | {:error, :timeout}
  defp wait_for_result(handle, task_id, caller_ref, team_name, agent_id, timeout_ms) do
    receive do
      {:task_result, ^caller_ref, result} ->
        duration_ms = Map.get(result, "duration_ms", 0)
        status = map_status(Map.get(result, "status", "completed"))
        emit_completed(task_id, agent_id, status, duration_ms)
        {:ok, convert_to_team_result(result, team_name)}
    after
      timeout_ms ->
        PendingTasks.cancel_task(handle.pending_tasks, task_id)
        emit_completed(task_id, agent_id, :timeout, 0)
        {:error, :timeout}
    end
  end

  @spec build_task_request(String.t(), String.t(), String.t(), non_neg_integer()) :: map()
  defp build_task_request(task_id, prompt, team_name, timeout_ms) do
    %{
      "task_id" => task_id,
      "prompt" => prompt,
      "tools" => [],
      "timeout_ms" => timeout_ms,
      "context" => %{
        "team_name" => team_name
      }
    }
  end

  @doc false
  @spec convert_to_team_result(map(), String.t()) :: TeamResult.t()
  def convert_to_team_result(result, team_name) do
    %TeamResult{
      team: team_name,
      status: map_status(Map.get(result, "status", "completed")),
      result: Map.get(result, "result_text"),
      duration_ms: Map.get(result, "duration_ms"),
      input_tokens: Map.get(result, "input_tokens"),
      output_tokens: Map.get(result, "output_tokens"),
      cost_usd: nil,
      session_id: nil,
      cache_read_tokens: nil,
      cache_creation_tokens: nil,
      num_turns: nil
    }
  end

  @spec map_status(String.t()) :: TeamResult.status()
  defp map_status("completed"), do: :success
  defp map_status("failed"), do: :error
  defp map_status("cancelled"), do: :error
  defp map_status(_unknown), do: :error

  @spec emit_dispatched(String.t(), String.t()) :: :ok
  defp emit_dispatched(task_id, agent_id) do
    Telemetry.emit_gateway_task_dispatched(%{task_id: task_id, agent_id: agent_id})
  end

  @spec emit_completed(String.t(), String.t(), atom(), non_neg_integer()) :: :ok
  defp emit_completed(task_id, agent_id, status, duration_ms) do
    Telemetry.emit_gateway_task_completed(%{
      task_id: task_id,
      agent_id: agent_id,
      status: status,
      duration_ms: duration_ms
    })
  end

  @spec update_agent_status(String.t(), atom()) :: :ok | {:error, term()}
  defp update_agent_status(agent_id, status) do
    Registry.update_status(agent_id, status)
  rescue
    _ -> :ok
  end

  @spec process_alive?(GenServer.server()) :: boolean()
  defp process_alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp process_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_alive?({:via, _, _}), do: true
  defp process_alive?({:global, _}), do: true
  defp process_alive?(_), do: true

  # Default push function - delegates to TaskPush when available.
  # This is overridable via :push_fn in config for test injection.
  @spec default_push(atom(), pid(), map()) :: {:ok, :sent} | {:error, term()}
  defp default_push(transport, pid, task_request) do
    TaskPush.push(transport, pid, task_request)
  end
end
