defmodule Cortex.Gossip.Coordinator.Lifecycle do
  @moduledoc """
  Manages the spawn/stop lifecycle of the gossip coordinator agent.

  The gossip coordinator runs for the entire duration of a gossip session,
  synthesizing knowledge, steering agents, and optionally terminating the
  session early when knowledge converges.
  """

  alias Cortex.Gossip.Config, as: GossipConfig
  alias Cortex.Gossip.Coordinator.Prompt
  alias Cortex.InternalAgent.Launcher
  alias Cortex.InternalAgent.SpawnConfig

  require Logger

  @doc """
  Spawns the gossip coordinator agent as an async Task.

  Builds the coordinator prompt, creates a TeamRun DB record,
  and delegates to `Launcher.run_async/1`.

  ## Parameters

    - `config` — the `%GossipConfig{}` struct
    - `workspace_path` — the project root directory
    - `command` — the CLI command string (e.g. `"claude"`)
    - `run_id` — the run ID for event broadcasting and DB records

  ## Returns

    - A `Task.t()` on success
    - `nil` if spawning fails
  """
  @spec spawn(GossipConfig.t(), String.t(), String.t(), String.t() | nil) :: Task.t() | nil
  def spawn(config, workspace_path, command, run_id) do
    prompt = Prompt.build(config, workspace_path)
    log_dir = Path.join([workspace_path, ".cortex", "logs"])
    File.mkdir_p!(log_dir)
    log_path = Path.join(log_dir, "coordinator.log")

    create_team_run(run_id, prompt, log_path)

    on_token_update = fn name, tokens ->
      broadcast(:team_tokens_updated, %{
        run_id: run_id,
        team_name: name,
        input_tokens: tokens.input_tokens,
        output_tokens: tokens.output_tokens,
        cache_read_tokens: tokens.cache_read_tokens,
        cache_creation_tokens: tokens.cache_creation_tokens
      })
    end

    on_activity = fn name, activity ->
      broadcast(:team_activity, %{
        run_id: run_id,
        team_name: name,
        type: Map.get(activity, :type, :unknown),
        tools: Map.get(activity, :tools, []),
        details: Map.get(activity, :details, []),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end

    spawn_config = %SpawnConfig{
      team_name: "coordinator",
      prompt: prompt,
      model: "haiku",
      max_turns: 500,
      permission_mode: "bypassPermissions",
      timeout_minutes: config.defaults.timeout_minutes,
      log_path: log_path,
      command: command,
      on_token_update: on_token_update,
      on_activity: on_activity
    }

    # Register in the RunnerRegistry before spawning so the UI can track it
    Task.async(fn ->
      if run_id do
        Registry.register(
          Cortex.Orchestration.RunnerRegistry,
          {:coordinator, run_id},
          %{started_at: DateTime.utc_now()}
        )
      end

      Launcher.run(spawn_config)
    end)
  rescue
    e ->
      Logger.warning("Failed to spawn gossip coordinator: #{inspect(e)}")
      nil
  end

  @doc """
  Stops the coordinator task.

  Yields for 5 seconds, then brutal-kills if the task hasn't finished.
  Safe to call with `nil` (no-op).
  """
  @spec stop(Task.t() | nil) :: :ok
  def stop(task), do: Launcher.stop(task)

  # -- DB Persistence --

  @spec create_team_run(String.t() | nil, String.t(), String.t()) :: :ok
  defp create_team_run(nil, _prompt, _log_path), do: :ok

  defp create_team_run(run_id, prompt, log_path) do
    Cortex.Store.upsert_internal_team_run(%{
      run_id: run_id,
      team_name: "coordinator",
      role: "Gossip Coordinator",
      tier: -1,
      internal: true,
      status: "running",
      prompt: prompt,
      log_path: log_path,
      started_at: DateTime.utc_now()
    })
  rescue
    _ -> :ok
  end

  @spec broadcast(atom(), map()) :: :ok
  defp broadcast(type, payload) do
    Cortex.Events.broadcast(type, payload)
    :ok
  rescue
    _ -> :ok
  end
end
