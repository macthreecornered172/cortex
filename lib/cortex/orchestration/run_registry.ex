defmodule Cortex.Orchestration.RunRegistry do
  @moduledoc """
  Run registry tracking all teams in an orchestration run.

  Serialized as JSON in the workspace's `registry.json` file. Each team
  gets a `RegistryEntry` with its name, status, session ID, PID, and
  timestamps.

  Named `RunRegistry` to avoid conflict with `Cortex.Tool.Registry`
  and Elixir's built-in `Registry`.

  ## Fields

    - `project` — the project name from the orchestra config
    - `teams` — list of `%RegistryEntry{}` structs
  """

  alias Cortex.Orchestration.RegistryEntry

  defstruct [:project, teams: []]

  @type t :: %__MODULE__{
          project: String.t() | nil,
          teams: [RegistryEntry.t()]
        }

  @doc """
  Converts a `RunRegistry` struct to a plain map for JSON encoding.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = registry) do
    %{
      "project" => registry.project,
      "teams" => Enum.map(registry.teams, &RegistryEntry.to_map/1)
    }
  end

  @doc """
  Constructs a `RunRegistry` struct from a decoded JSON map.
  """
  @spec from_map(map()) :: t()
  def from_map(%{"project" => project, "teams" => teams_list}) do
    teams = Enum.map(teams_list, &RegistryEntry.from_map/1)
    %__MODULE__{project: project, teams: teams}
  end

  def from_map(%{"project" => project}) do
    %__MODULE__{project: project, teams: []}
  end

  @doc """
  Finds a registry entry by team name.

  Returns `{:ok, entry}` or `:error` if no entry with that name exists.
  """
  @spec find_entry(t(), String.t()) :: {:ok, RegistryEntry.t()} | :error
  def find_entry(%__MODULE__{teams: teams}, team_name) do
    case Enum.find(teams, fn entry -> entry.name == team_name end) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc """
  Updates (or inserts) a registry entry for the given team name.

  If an entry with `team_name` already exists, merges the `updates` keyword
  list into it. If no entry exists, creates a new `RegistryEntry` with the
  given name and updates.

  Returns the updated `RunRegistry`.
  """
  @spec update_entry(t(), String.t(), keyword()) :: t()
  def update_entry(%__MODULE__{teams: teams} = registry, team_name, updates) do
    case Enum.find_index(teams, fn entry -> entry.name == team_name end) do
      nil ->
        new_entry = struct(RegistryEntry, [{:name, team_name} | updates])
        %{registry | teams: teams ++ [new_entry]}

      index ->
        updated_entry = struct(Enum.at(teams, index), updates)
        %{registry | teams: List.replace_at(teams, index, updated_entry)}
    end
  end
end

defmodule Cortex.Orchestration.RegistryEntry do
  @moduledoc """
  A single team's entry in the run registry.

  ## Fields

    - `name` — team name (matches team name in config)
    - `status` — one of `"pending"`, `"running"`, `"done"`, `"failed"`
    - `session_id` — the claude -p session ID (captured from stream-json init event)
    - `pid` — the OS PID of the spawned claude process (stored as integer)
    - `started_at` — ISO 8601 timestamp when the team started
    - `ended_at` — ISO 8601 timestamp when the team finished
  """

  defstruct [:name, :status, :session_id, :pid, :started_at, :ended_at]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          status: String.t() | nil,
          session_id: String.t() | nil,
          pid: integer() | nil,
          started_at: String.t() | nil,
          ended_at: String.t() | nil
        }

  @doc """
  Converts a `RegistryEntry` struct to a plain map for JSON encoding.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry) do
    %{
      "name" => entry.name,
      "status" => entry.status,
      "session_id" => entry.session_id,
      "pid" => entry.pid,
      "started_at" => entry.started_at,
      "ended_at" => entry.ended_at
    }
  end

  @doc """
  Constructs a `RegistryEntry` struct from a decoded JSON map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: Map.get(map, "name"),
      status: Map.get(map, "status"),
      session_id: Map.get(map, "session_id"),
      pid: Map.get(map, "pid"),
      started_at: Map.get(map, "started_at"),
      ended_at: Map.get(map, "ended_at")
    }
  end
end
