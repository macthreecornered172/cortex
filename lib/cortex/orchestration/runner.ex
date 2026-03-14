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

  alias Cortex.Orchestration.Config
  alias Cortex.Orchestration.Config.Loader
  alias Cortex.Orchestration.DAG
  alias Cortex.Orchestration.Spawner
  alias Cortex.Orchestration.State
  alias Cortex.Orchestration.Summary
  alias Cortex.Orchestration.TeamResult
  alias Cortex.Orchestration.Workspace

  require Logger

  @default_task_timeout_ms :timer.minutes(60)

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
    command = Keyword.get(opts, :command, "claude")

    with {:ok, config, _warnings} <- Loader.load(config_path),
         {:ok, tiers} <- DAG.build_tiers(config.teams) do
      if dry_run do
        build_dry_run_plan(config, tiers)
      else
        execute(config, tiers, workspace_path, command, continue_on_error)
      end
    else
      {:error, _} = error -> error
    end
  end

  # -- Dry Run -----------------------------------------------------------------

  @spec build_dry_run_plan(Config.t(), [[String.t()]]) :: {:ok, map()}
  defp build_dry_run_plan(config, tiers) do
    tier_plans =
      tiers
      |> Enum.with_index()
      |> Enum.map(fn {team_names, index} ->
        teams =
          Enum.map(team_names, fn name ->
            team = find_team(config.teams, name)
            model = team_model(team, config.defaults)
            %{name: name, role: team.lead.role, model: model}
          end)

        %{tier: index, teams: teams}
      end)

    {:ok,
     %{
       status: :dry_run,
       project: config.name,
       tiers: tier_plans,
       total_teams: length(config.teams)
     }}
  end

  # -- Execution ---------------------------------------------------------------

  @spec execute(Config.t(), [[String.t()]], String.t(), String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  defp execute(config, tiers, workspace_path, command, continue_on_error) do
    team_names = Enum.map(config.teams, & &1.name)
    ws_config = %{project: config.name, teams: team_names}

    with {:ok, workspace} <- Workspace.init(workspace_path, ws_config) do
      broadcast(:run_started, %{project: config.name, teams: team_names})

      run_start = System.monotonic_time(:millisecond)

      result =
        run_tiers(tiers, config, workspace, command, continue_on_error)

      run_duration = System.monotonic_time(:millisecond) - run_start

      case result do
        {:ok, _} ->
          broadcast(:run_completed, %{project: config.name, duration_ms: run_duration})
          build_summary(config, workspace, run_duration)

        {:error, {:tier_failed, _tier_index, _failures}} = error ->
          broadcast(:run_completed, %{
            project: config.name,
            duration_ms: run_duration,
            status: :failed
          })

          error
      end
    end
  end

  @spec run_tiers([[String.t()]], Config.t(), Workspace.t(), String.t(), boolean()) ::
          {:ok, :complete} | {:error, {:tier_failed, non_neg_integer(), [String.t()]}}
  defp run_tiers(tiers, config, workspace, command, continue_on_error) do
    tiers
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, :complete}, fn {team_names, tier_index}, acc ->
      broadcast(:tier_started, %{tier: tier_index, teams: team_names})

      # Read state once before the tier starts (for prompt building)
      {:ok, state} = Workspace.read_state(workspace)

      # Mark all teams in this tier as "running" sequentially before spawning
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      Enum.each(team_names, fn name ->
        Workspace.update_team_state(workspace, name, status: "running")
        Workspace.update_registry_entry(workspace, name, status: "running", started_at: now)
      end)

      # Spawn all teams in parallel, each returns an outcome tuple
      outcomes =
        team_names
        |> Enum.map(fn name ->
          Task.async(fn ->
            run_team(name, config, workspace, state, command)
          end)
        end)
        |> Task.await_many(@default_task_timeout_ms)

      # Apply workspace updates sequentially to avoid read-modify-write races
      Enum.each(outcomes, fn outcome ->
        apply_outcome(workspace, outcome)
      end)

      failures =
        outcomes
        |> Enum.filter(fn {_name, status, _data} -> status != :ok end)
        |> Enum.map(fn {name, _, _} -> name end)

      broadcast(:tier_completed, %{tier: tier_index, teams: team_names, failures: failures})

      cond do
        failures == [] ->
          {:cont, acc}

        continue_on_error ->
          {:cont, acc}

        true ->
          {:halt, {:error, {:tier_failed, tier_index, failures}}}
      end
    end)
  end

  # Each team task returns {name, :ok | {:error, reason}, outcome_data}
  # outcome_data is a map with the info needed to update workspace

  @spec run_team(String.t(), Config.t(), Workspace.t(), State.t(), String.t()) ::
          {String.t(), :ok | {:error, term()}, map()}
  defp run_team(team_name, config, workspace, state, command) do
    team = find_team(config.teams, team_name)
    model = team_model(team, config.defaults)
    max_turns = config.defaults.max_turns
    permission_mode = config.defaults.permission_mode
    timeout_minutes = config.defaults.timeout_minutes
    prompt = build_prompt(team, config.name, state)
    log_path = Workspace.log_path(workspace, team_name)

    spawner_opts = [
      team_name: team_name,
      prompt: prompt,
      model: model,
      max_turns: max_turns,
      permission_mode: permission_mode,
      timeout_minutes: timeout_minutes,
      log_path: log_path,
      command: command
    ]

    case Spawner.spawn(spawner_opts) do
      {:ok, %TeamResult{status: :success} = result} ->
        {team_name, :ok, %{type: :success, result: result}}

      {:ok, %TeamResult{} = result} ->
        {team_name, {:error, result.status}, %{type: :failure, result: result}}

      {:error, reason} ->
        {team_name, {:error, reason}, %{type: :error, reason: reason}}
    end
  end

  # -- Workspace Update (called sequentially, no races) -------------------------

  @spec apply_outcome(Workspace.t(), {String.t(), term(), map()}) :: :ok
  defp apply_outcome(workspace, {team_name, _status, %{type: :success, result: result}}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Workspace.update_team_state(workspace, team_name,
      status: "done",
      result_summary: result.result,
      cost_usd: result.cost_usd,
      duration_ms: result.duration_ms
    )

    Workspace.update_registry_entry(workspace, team_name,
      status: "done",
      session_id: result.session_id,
      ended_at: now
    )

    write_team_result(workspace, team_name, result)
    :ok
  end

  defp apply_outcome(workspace, {team_name, _status, %{type: :failure, result: result}}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Workspace.update_team_state(workspace, team_name,
      status: "failed",
      result_summary: result.result,
      cost_usd: result.cost_usd,
      duration_ms: result.duration_ms
    )

    Workspace.update_registry_entry(workspace, team_name,
      status: "failed",
      session_id: result.session_id,
      ended_at: now
    )

    write_team_result(workspace, team_name, result)
    :ok
  end

  defp apply_outcome(workspace, {team_name, _status, %{type: :error, reason: reason}}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Workspace.update_team_state(workspace, team_name,
      status: "failed",
      result_summary: "Error: #{inspect(reason)}"
    )

    Workspace.update_registry_entry(workspace, team_name,
      status: "failed",
      ended_at: now
    )

    :ok
  end

  @spec write_team_result(Workspace.t(), String.t(), TeamResult.t()) :: :ok | {:error, term()}
  defp write_team_result(workspace, team_name, result) do
    result_map = %{
      "team" => result.team,
      "status" => Atom.to_string(result.status),
      "result" => result.result,
      "cost_usd" => result.cost_usd,
      "num_turns" => result.num_turns,
      "duration_ms" => result.duration_ms,
      "session_id" => result.session_id
    }

    Workspace.write_result(workspace, team_name, result_map)
  end

  # -- Prompt Building (inline, since Injection module doesn't exist yet) ------

  @spec build_prompt(Config.Team.t(), String.t(), State.t()) :: String.t()
  defp build_prompt(team, project_name, state) do
    sections = [
      "You are: #{team.lead.role}",
      "Project: #{project_name}",
      "",
      build_context_section(team),
      build_tasks_section(team),
      build_upstream_section(team, state),
      build_team_section(team),
      build_instructions_section()
    ]

    sections
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp build_context_section(%{context: nil}), do: nil

  defp build_context_section(%{context: context}) do
    ["## Technical Context", "", context]
  end

  defp build_tasks_section(%{tasks: tasks}) do
    task_lines =
      tasks
      |> Enum.with_index(1)
      |> Enum.map(fn {task, i} ->
        lines = ["#{i}. #{task.summary}"]
        lines = if task.details, do: lines ++ ["   #{task.details}"], else: lines

        lines =
          if task.deliverables != [],
            do: lines ++ ["   Deliverables: #{Enum.join(task.deliverables, ", ")}"],
            else: lines

        lines = if task.verify, do: lines ++ ["   Verify: #{task.verify}"], else: lines
        Enum.join(lines, "\n")
      end)

    ["## Your Tasks", "" | task_lines]
  end

  defp build_upstream_section(%{depends_on: []}, _state), do: nil
  defp build_upstream_section(%{depends_on: nil}, _state), do: nil

  defp build_upstream_section(%{depends_on: deps}, state) do
    dep_lines =
      Enum.map(deps, fn dep_name ->
        case Map.get(state.teams, dep_name) do
          nil ->
            "- #{dep_name}: (no results yet)"

          ts ->
            summary = ts.result_summary || "(no summary)"
            "- #{dep_name}: #{summary}"
        end
      end)

    ["## Context from Previous Teams", "" | dep_lines]
  end

  defp build_team_section(%{members: []}), do: nil

  defp build_team_section(%{members: members}) do
    member_lines =
      Enum.map(members, fn m ->
        focus = if m.focus, do: " -- #{m.focus}", else: ""
        "- #{m.role}#{focus}"
      end)

    [
      "## Your Team",
      "",
      "You are the team lead. Delegate tasks to your team members:" | member_lines
    ]
  end

  defp build_instructions_section do
    [
      "",
      "## Instructions",
      "",
      "Work through tasks in order. Run verify commands after each.",
      "Provide a summary of what you accomplished and files created/modified."
    ]
  end

  # -- Helpers -----------------------------------------------------------------

  defp find_team(teams, name) do
    Enum.find(teams, fn t -> t.name == name end)
  end

  defp team_model(%{lead: %{model: model}}, _defaults) when is_binary(model), do: model
  defp team_model(_team, defaults), do: defaults.model

  @spec build_summary(Config.t(), Workspace.t(), non_neg_integer()) :: {:ok, map()}
  defp build_summary(config, workspace, wall_clock_ms) do
    {:ok, state} = Workspace.read_state(workspace)

    total_cost =
      state.teams
      |> Map.values()
      |> Enum.map(fn ts -> ts.cost_usd || 0.0 end)
      |> Enum.sum()

    total_duration =
      state.teams
      |> Map.values()
      |> Enum.map(fn ts -> ts.duration_ms || 0 end)
      |> Enum.sum()

    overall_status =
      if Enum.any?(Map.values(state.teams), fn ts -> ts.status == "failed" end),
        do: :failed,
        else: :complete

    team_results =
      Enum.map(state.teams, fn {name, ts} ->
        {name,
         %{
           status: ts.status,
           cost_usd: ts.cost_usd,
           duration_ms: ts.duration_ms,
           result_summary: ts.result_summary
         }}
      end)
      |> Map.new()

    summary_text = Summary.format(state)

    {:ok,
     %{
       status: overall_status,
       project: config.name,
       teams: team_results,
       total_cost: total_cost,
       total_duration_ms: total_duration,
       wall_clock_ms: wall_clock_ms,
       summary: summary_text
     }}
  end

  @spec broadcast(atom(), map()) :: :ok
  defp broadcast(type, payload) do
    Cortex.Events.broadcast(type, payload)
    :ok
  rescue
    # If PubSub is not started (e.g., in tests), silently continue
    _ -> :ok
  end
end
