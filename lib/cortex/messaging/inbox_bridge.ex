defmodule Cortex.Messaging.InboxBridge do
  @moduledoc """
  Bridges native Cortex messaging to file-based inboxes for claude -p sessions.

  Each team gets an inbox file at `.cortex/messages/<team_name>/inbox.json`.
  Messages are appended as a JSON array. Claude sessions read this file
  via a /loop to receive mid-flight guidance.

  ## Directory Layout

      .cortex/messages/
      +-- <team_name>/
          +-- inbox.json    # messages TO this team (from coordinator or other teams)
          +-- outbox.json   # messages FROM this team (written by the claude -p session)

  """

  alias Cortex.Orchestration.FileUtils

  @doc """
  Returns the message directory path for a team.

  ## Parameters

    - `workspace_path` -- the project root directory
    - `team_name` -- the team name string

  ## Returns

  A path string: `<workspace_path>/.cortex/messages/<team_name>/`
  """
  @spec inbox_dir(String.t(), String.t()) :: String.t()
  def inbox_dir(workspace_path, team_name) do
    Path.join([workspace_path, ".cortex", "messages", team_name])
  end

  @doc """
  Returns the inbox file path for a team.

  ## Parameters

    - `workspace_path` -- the project root directory
    - `team_name` -- the team name string

  ## Returns

  A path string: `<workspace_path>/.cortex/messages/<team_name>/inbox.json`
  """
  @spec inbox_path(String.t(), String.t()) :: String.t()
  def inbox_path(workspace_path, team_name) do
    Path.join(inbox_dir(workspace_path, team_name), "inbox.json")
  end

  @doc """
  Returns the outbox file path for a team.

  ## Parameters

    - `workspace_path` -- the project root directory
    - `team_name` -- the team name string

  ## Returns

  A path string: `<workspace_path>/.cortex/messages/<team_name>/outbox.json`
  """
  @spec outbox_path(String.t(), String.t()) :: String.t()
  def outbox_path(workspace_path, team_name) do
    Path.join(inbox_dir(workspace_path, team_name), "outbox.json")
  end

  @doc """
  Creates message directories and empty inbox/outbox files for each team.

  ## Parameters

    - `workspace_path` -- the project root directory
    - `team_names` -- list of team name strings

  ## Returns

  `:ok`
  """
  @spec setup(String.t(), [String.t()]) :: :ok
  def setup(workspace_path, team_names) do
    Enum.each(team_names, fn team_name ->
      dir = inbox_dir(workspace_path, team_name)
      File.mkdir_p!(dir)

      inbox = inbox_path(workspace_path, team_name)
      outbox = outbox_path(workspace_path, team_name)

      unless File.exists?(inbox) do
        FileUtils.atomic_write(inbox, Jason.encode!([], pretty: true))
      end

      unless File.exists?(outbox) do
        FileUtils.atomic_write(outbox, Jason.encode!([], pretty: true))
      end
    end)

    :ok
  end

  @doc """
  Delivers a message to a team's inbox.

  Reads the current inbox.json, appends the new message, and writes back
  atomically using `FileUtils.atomic_write/2`.

  ## Parameters

    - `workspace_path` -- the project root directory
    - `team_name` -- the recipient team name
    - `message` -- a map with `:from`, `:content`, `:timestamp`, and `:type` keys

  ## Returns

  `:ok`
  """
  @spec deliver(String.t(), String.t(), map()) :: :ok
  def deliver(workspace_path, team_name, message) do
    path = inbox_path(workspace_path, team_name)
    {:ok, existing} = read_json_array(path)
    updated = existing ++ [normalize_message(message)]
    FileUtils.atomic_write(path, Jason.encode!(updated, pretty: true))
  end

  @doc """
  Reads and parses a team's inbox.json file.

  ## Parameters

    - `workspace_path` -- the project root directory
    - `team_name` -- the team name string

  ## Returns

  `{:ok, [map()]}` -- a list of message maps
  """
  @spec read_inbox(String.t(), String.t()) :: {:ok, [map()]}
  def read_inbox(workspace_path, team_name) do
    path = inbox_path(workspace_path, team_name)
    read_json_array(path)
  end

  @doc """
  Reads messages the team wrote to its outbox.

  ## Parameters

    - `workspace_path` -- the project root directory
    - `team_name` -- the team name string

  ## Returns

  `{:ok, [map()]}` -- a list of message maps
  """
  @spec read_outbox(String.t(), String.t()) :: {:ok, [map()]}
  def read_outbox(workspace_path, team_name) do
    path = outbox_path(workspace_path, team_name)
    read_json_array(path)
  end

  @doc """
  Delivers the same message to all teams' inboxes.

  ## Parameters

    - `workspace_path` -- the project root directory
    - `team_names` -- list of team name strings
    - `message` -- a map with `:from`, `:content`, `:timestamp`, and `:type` keys

  ## Returns

  `:ok`
  """
  @spec broadcast(String.t(), [String.t()], map()) :: :ok
  def broadcast(workspace_path, team_names, message) do
    Enum.each(team_names, fn team_name ->
      deliver(workspace_path, team_name, message)
    end)

    :ok
  end

  # --- Private Helpers ---

  @spec read_json_array(String.t()) :: {:ok, [map()]}
  defp read_json_array(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) -> {:ok, list}
          _ -> {:ok, []}
        end

      {:error, :enoent} ->
        {:ok, []}
    end
  end

  @spec normalize_message(map()) :: map()
  defp normalize_message(message) do
    message
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end
end
