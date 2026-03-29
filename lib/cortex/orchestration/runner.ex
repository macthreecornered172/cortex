defmodule Cortex.Orchestration.Runner do
  @moduledoc """
  The main orchestration engine that executes multi-team projects end-to-end.

  `run/2` is the top-level entry point. It loads a YAML config, builds a DAG
  of execution tiers, initializes a workspace, then walks through each tier
  spawning teams in parallel. Results from earlier tiers are injected as
  context into later tiers.

  ## Flow

  1. Load and validate config via `Config.Loader.load/1`
  2. Initialize workspace via `Workspace.init/2`
  3. Build DAG tiers via `DAG.build_tiers/1`
  4. Broadcast `:run_started`
  5. For each tier:
     - Broadcast `:tier_started`
     - Spawn all teams in the tier as concurrent `Task`s
     - Each task: build prompt, call `Spawner.spawn/1`, return outcome
     - Await all tasks, then apply workspace updates sequentially
     - If any failed and `continue_on_error` is false, stop early
     - Broadcast `:tier_completed`
  6. Broadcast `:run_completed`
  7. Return `{:ok, summary_map}`

  ## Sub-modules

    - `Runner.Executor` — core DAG tier walking, team spawning, coordinator
    - `Runner.Outcomes` — workspace + DB state updates after team completion
    - `Runner.Reconciler` — dead team recovery and run reconciliation
    - `Runner.Store` — safe DB operation wrappers

  ## Options

    - `:continue_on_error` -- `false` (default). If true, continue to the
      next tier even when a team in the current tier fails.
    - `:dry_run` -- `false` (default). If true, return the execution plan
      without spawning any processes.
    - `:workspace_path` -- `"."` (default). The directory where `.cortex/`
      will be created.
    - `:command` -- `"claude"` (default). Override the spawner command
      (useful for tests with a mock script).

  """

  alias Cortex.Messaging.InboxBridge
  alias Cortex.Orchestration.Config.Loader
  alias Cortex.Orchestration.DAG
  alias Cortex.Orchestration.Runner.Executor
  alias Cortex.Orchestration.Runner.Reconciler

  require Logger

  @doc """
  Runs a full orchestration from a YAML config file.

  Loads the config, builds the DAG, initializes the workspace, and executes
  each tier of teams in parallel. Returns a summary map on success.

  ## Parameters

    - `config_path` -- path to the `orchestra.yaml` file
    - `opts` -- keyword list of options (see module doc)

  ## Returns

    - `{:ok, summary_map}` -- on success, a map with `:status`, `:project`,
      `:teams`, `:total_cost`, `:total_duration_ms`, and `:summary` keys
    - `{:error, term()}` -- on failure

  ## Examples

      iex> Runner.run("path/to/orchestra.yaml", command: "/path/to/mock")
      {:ok, %{status: :complete, project: "demo", ...}}

  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(config_path, opts \\ []) do
    continue_on_error = Keyword.get(opts, :continue_on_error, false)
    dry_run = Keyword.get(opts, :dry_run, false)
    workspace_path = Keyword.get(opts, :workspace_path, ".")
    command = Keyword.get(opts, :command, default_command())
    run_id = Keyword.get(opts, :run_id)
    coordinator = Keyword.get(opts, :coordinator, false)

    with {:ok, config, _warnings} <- Loader.load(config_path),
         {:ok, tiers} <- DAG.build_tiers(config.teams) do
      if dry_run do
        Executor.build_dry_run_plan(config, tiers)
      else
        Executor.execute(
          config,
          tiers,
          workspace_path,
          command,
          continue_on_error,
          run_id,
          coordinator
        )
      end
    else
      {:error, _} = error -> error
    end
  end

  @doc """
  Checks whether a Runner coordinator process is alive for a given run.

  Returns `true` if a process registered under `{:coordinator, run_id}` exists
  and is alive, `false` otherwise. Uses an Elixir Registry lookup (ETS),
  so this is very fast.
  """
  @spec coordinator_alive?(String.t()) :: boolean()
  def coordinator_alive?(run_id) do
    case Registry.lookup(Cortex.Orchestration.RunnerRegistry, {:coordinator, run_id}) do
      [{pid, _value}] -> Process.alive?(pid)
      [] -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Checks whether the Runner executor process is alive for a given run.

  The executor is the process that actually walks DAG tiers and spawns teams.
  This is the authoritative check for whether a run is still in progress —
  the coordinator is optional monitoring and may exit independently.
  """
  @spec runner_alive?(String.t()) :: boolean()
  def runner_alive?(run_id) do
    case Registry.lookup(Cortex.Orchestration.RunnerRegistry, {:runner, run_id}) do
      [{pid, _value}] -> Process.alive?(pid)
      [] -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Sends a message to a running team's file-based inbox.

  Delivers a message to the team's inbox file so that the team's
  `claude -p` session can pick it up via its `/loop` polling.

  ## Parameters

    - `workspace_path` -- the project root directory
    - `from` -- sender identifier (e.g. "coordinator" or another team name)
    - `to_team` -- the recipient team name
    - `content` -- the message content string

  ## Returns

  `:ok`
  """
  @spec send_message(String.t(), String.t(), String.t(), String.t()) :: :ok
  def send_message(workspace_path, from, to_team, content) do
    message = %{
      from: from,
      to: to_team,
      content: content,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: "message"
    }

    InboxBridge.deliver(workspace_path, to_team, message)
  end

  @doc """
  Resumes dead teams in a previously started run.

  Delegates to `Runner.Reconciler.resume_run/3`.
  """
  @spec resume_run(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate resume_run(run_id, workspace_path, opts \\ []), to: Reconciler

  @doc """
  Reconciles workspace state by scanning log files for completed sessions.

  Delegates to `Runner.Reconciler.reconcile_run/2`.
  """
  @spec reconcile_run(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate reconcile_run(run_id, opts \\ []), to: Reconciler

  @doc """
  Continues a run that was interrupted (e.g., Runner process died, terminal closed).

  Reads the run's config_yaml from the DB, rebuilds the DAG, identifies which
  teams already completed, and executes the remaining tiers from where the run
  left off.

  ## Parameters

    - `run_id` — the UUID of the run to continue
    - `opts` — keyword options:
      - `:command` — override the claude command (default "claude")
      - `:continue_on_error` — continue past tier failures (default true)

  ## Returns

    - `{:ok, summary_map}` — on success
    - `{:error, reason}` — on failure

  """
  @spec continue_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def continue_run(run_id, opts \\ []) do
    command = Keyword.get(opts, :command, default_command())
    continue_on_error = Keyword.get(opts, :continue_on_error, true)

    coordinator = Keyword.get(opts, :coordinator, nil)

    with {:ok, run} <- fetch_run(run_id),
         {:ok, _yaml} <- validate_run_config(run),
         {:ok, _path} <- validate_run_workspace(run),
         {:ok, config, _warnings} <- load_run_config(run),
         {:ok, all_tiers} <- DAG.build_tiers(config.teams) do
      # If coordinator not explicitly set, infer from provider
      spawn_coordinator =
        if is_nil(coordinator),
          do: config.defaults.provider != :external,
          else: coordinator

      Executor.execute_continuation(
        run,
        config,
        all_tiers,
        command,
        continue_on_error,
        spawn_coordinator
      )
    end
  end

  @doc """
  Approves a gated run, allowing it to continue execution.

  Idempotent: if the run is not in "gated" status, returns `{:ok, :noop}`.

  ## Options

    - `:decided_by` — who approved (string)
    - `:notes` — optional notes injected into downstream agent prompts
    - `:command` — override the claude command (default "claude")
    - `:continue_on_error` — continue past tier failures (default true)

  """
  @spec approve_gate(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def approve_gate(run_id, opts \\ []) do
    with {:ok, run} <- fetch_run(run_id),
         :gated <- check_gated(run) do
      resolve_pending_gate(run_id, "approved", opts)

      Cortex.Store.update_run(run, %{status: "running", gated_at_tier: nil})
      Cortex.Events.broadcast(:gate_approved, %{run_id: run_id, tier: run.gated_at_tier})

      continue_run(run_id, opts)
    else
      :not_gated -> {:ok, :noop}
      error -> error
    end
  end

  @doc """
  Rejects a gated run, cancelling it permanently.

  Idempotent: if the run is not in "gated" status, returns `{:ok, :noop}`.

  ## Options

    - `:decided_by` — who rejected (string)
    - `:notes` — optional reason for rejection

  """
  @spec reject_gate(String.t(), keyword()) :: {:ok, :rejected | :noop} | {:error, term()}
  def reject_gate(run_id, opts \\ []) do
    with {:ok, run} <- fetch_run(run_id),
         :gated <- check_gated(run) do
      resolve_pending_gate(run_id, "rejected", opts)

      Cortex.Store.update_run(run, %{
        status: "cancelled",
        gated_at_tier: nil,
        completed_at: DateTime.utc_now()
      })

      Cortex.Events.broadcast(:run_cancelled, %{run_id: run_id})
      {:ok, :rejected}
    else
      :not_gated -> {:ok, :noop}
      error -> error
    end
  end

  @doc """
  Cancels any active run (running or gated).

  For running runs: looks up the executor process and sends a shutdown signal,
  then marks the run and incomplete team_runs as cancelled.

  For gated runs: equivalent to `reject_gate/2` without requiring notes.

  Idempotent: if the run is already completed/failed/cancelled, returns `{:ok, :noop}`.
  """
  @spec cancel_run(String.t()) :: {:ok, :cancelled | :noop} | {:error, term()}
  def cancel_run(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      do_cancel(run_id, run)
    end
  end

  defp do_cancel(_run_id, %{status: status})
       when status in ["completed", "failed", "cancelled", "stopped"],
       do: {:ok, :noop}

  defp do_cancel(run_id, %{status: "gated"}),
    do: reject_gate(run_id, notes: "Cancelled by user")

  defp do_cancel(run_id, run) do
    stop_runner_process(run_id)
    cancel_incomplete_teams(run_id)

    Cortex.Store.update_run(run, %{
      status: "cancelled",
      completed_at: DateTime.utc_now()
    })

    Cortex.Events.broadcast(:run_cancelled, %{run_id: run_id})
    {:ok, :cancelled}
  end

  defp cancel_incomplete_teams(run_id) do
    run_id
    |> Cortex.Store.get_team_runs()
    |> Enum.filter(fn tr -> tr.status in ["pending", "running"] end)
    |> Enum.each(fn tr ->
      Cortex.Store.update_team_run(tr, %{
        status: "cancelled",
        completed_at: DateTime.utc_now()
      })
    end)
  end

  defp default_command, do: System.get_env("CLAUDE_COMMAND") || "claude"

  defp check_gated(%{status: "gated"}), do: :gated
  defp check_gated(_run), do: :not_gated

  defp resolve_pending_gate(run_id, decision, opts) do
    decided_by = Keyword.get(opts, :decided_by)
    notes = Keyword.get(opts, :notes)

    case Cortex.Store.get_pending_gate(run_id) do
      nil ->
        :ok

      gd ->
        Cortex.Store.update_gate_decision(gd, %{
          decision: decision,
          decided_by: decided_by,
          notes: notes
        })
    end
  end

  defp stop_runner_process(run_id) do
    # Stop coordinator first (stops dispatching new work)
    case Registry.lookup(Cortex.Orchestration.RunnerRegistry, {:coordinator, run_id}) do
      [{pid, _}] ->
        if Process.alive?(pid), do: Process.exit(pid, :shutdown)

      [] ->
        :ok
    end

    # Stop the executor
    case Registry.lookup(Cortex.Orchestration.RunnerRegistry, {:runner, run_id}) do
      [{pid, _}] ->
        if Process.alive?(pid), do: Process.exit(pid, :shutdown)

      [] ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp fetch_run(run_id) do
    run =
      try do
        Cortex.Store.get_run(run_id)
      rescue
        _ -> nil
      end

    if is_nil(run), do: {:error, :run_not_found}, else: {:ok, run}
  end

  defp validate_run_config(run) do
    if is_nil(run.config_yaml), do: {:error, :no_config_yaml}, else: {:ok, run.config_yaml}
  end

  defp validate_run_workspace(run) do
    if is_nil(run.workspace_path),
      do: {:error, :no_workspace_path},
      else: {:ok, run.workspace_path}
  end

  defp load_run_config(run) do
    case Loader.load_string(run.config_yaml) do
      {:ok, config, warnings} -> {:ok, config, warnings}
      {:error, errors} -> {:error, {:invalid_config, errors}}
    end
  end
end
