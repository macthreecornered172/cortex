defmodule Cortex.InternalAgent.SpawnConfig do
  @moduledoc """
  Configuration struct for spawning internal `claude -p` agents.

  Wraps the keyword-list options that `Spawner.spawn/1` expects into an
  enforced struct so every internal agent (summary, debug, DAG coordinator,
  gossip coordinator) builds its config the same way.

  ## Usage

      config = %SpawnConfig{
        team_name: "summary-agent",
        prompt: "...",
        model: "haiku",
        max_turns: 1,
        permission_mode: "bypassPermissions",
        timeout_minutes: 2
      }

      Spawner.spawn(SpawnConfig.to_spawner_opts(config))
  """

  @enforce_keys [:team_name, :prompt, :model, :max_turns, :permission_mode, :timeout_minutes]
  defstruct [
    :team_name,
    :prompt,
    :model,
    :max_turns,
    :permission_mode,
    :timeout_minutes,
    :log_path,
    :cwd,
    :on_token_update,
    :on_activity,
    :on_port_opened,
    command: "claude"
  ]

  @type t :: %__MODULE__{
          team_name: String.t(),
          prompt: String.t(),
          model: String.t(),
          max_turns: pos_integer(),
          permission_mode: String.t(),
          timeout_minutes: number(),
          log_path: String.t() | nil,
          cwd: String.t() | nil,
          command: String.t(),
          on_token_update: (String.t(), map() -> any()) | nil,
          on_activity: (String.t(), map() -> any()) | nil,
          on_port_opened: (String.t(), pid() | nil -> any()) | nil
        }

  @doc """
  Extracts per-run options for `Provider.run/3`, excluding the prompt and
  provider-level config (command, cwd).

  These options are the runtime settings that vary per invocation:
  team name, model, max turns, permission mode, timeout, callbacks, etc.

  Nil optional fields are omitted from the output.
  """
  @spec to_run_opts(t()) :: keyword()
  def to_run_opts(%__MODULE__{} = config) do
    [
      team_name: config.team_name,
      model: config.model,
      max_turns: config.max_turns,
      permission_mode: config.permission_mode,
      timeout_minutes: config.timeout_minutes
    ]
    |> maybe_add(:log_path, config.log_path)
    |> maybe_add(:on_token_update, config.on_token_update)
    |> maybe_add(:on_activity, config.on_activity)
    |> maybe_add(:on_port_opened, config.on_port_opened)
  end

  @doc """
  Converts the struct to the keyword list that `Spawner.spawn/1` expects.

  Nil optional fields are omitted from the output.
  """
  @spec to_spawner_opts(t()) :: keyword()
  def to_spawner_opts(%__MODULE__{} = config) do
    [
      team_name: config.team_name,
      prompt: config.prompt,
      model: config.model,
      max_turns: config.max_turns,
      permission_mode: config.permission_mode,
      timeout_minutes: config.timeout_minutes,
      command: config.command
    ]
    |> maybe_add(:log_path, config.log_path)
    |> maybe_add(:cwd, config.cwd)
    |> maybe_add(:on_token_update, config.on_token_update)
    |> maybe_add(:on_activity, config.on_activity)
    |> maybe_add(:on_port_opened, config.on_port_opened)
  end

  @spec maybe_add(keyword(), atom(), term()) :: keyword()
  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
