defmodule Cortex.Orchestration.DAG do
  @moduledoc """
  DAG engine for topological sorting of teams into execution tiers.

  Takes a list of team structs (or maps with `:name` and `:depends_on` fields)
  and produces a list of tiers — each tier is a list of team names that can
  execute in parallel. Tiers execute sequentially: tier N+1 only starts after
  all teams in tier N have completed.

  Uses Kahn's algorithm for cycle-safe topological sort:

  1. Build adjacency list and in-degree map from `depends_on`
  2. Seed the queue with teams whose in-degree is 0 (no unmet dependencies)
  3. Each iteration: the current queue becomes one tier; decrement dependents' in-degree
  4. If total processed < total teams, a cycle exists

  ## Examples

      iex> teams = [
      ...>   %{name: "backend", depends_on: []},
      ...>   %{name: "frontend", depends_on: ["backend"]},
      ...>   %{name: "devops", depends_on: ["backend"]},
      ...>   %{name: "integration", depends_on: ["frontend", "devops"]}
      ...> ]
      iex> {:ok, tiers} = Cortex.Orchestration.DAG.build_tiers(teams)
      iex> tiers
      [["backend"], ["devops", "frontend"], ["integration"]]

  """

  @type team :: %{name: String.t(), depends_on: [String.t()]}
  @type tier :: [String.t()]

  @doc """
  Builds execution tiers from a list of teams using Kahn's algorithm.

  Each tier is a list of team names that can execute concurrently. Teams
  within the same tier have no dependencies on each other — all their
  dependencies are satisfied by earlier tiers.

  Returns `{:ok, tiers}` on success, where `tiers` is a list of lists of
  team name strings. Teams within each tier are sorted alphabetically for
  deterministic output.

  Returns `{:error, :cycle}` if the dependency graph contains a cycle.

  Returns `{:error, :unknown_dependency, name}` if a team's `depends_on`
  references a team name that does not exist in the input list.

  ## Parameters

    - `teams` — a list of maps or structs with `:name` (string) and
      `:depends_on` (list of strings) fields

  ## Examples

      iex> Cortex.Orchestration.DAG.build_tiers([])
      {:ok, []}

      iex> Cortex.Orchestration.DAG.build_tiers([%{name: "solo", depends_on: []}])
      {:ok, [["solo"]]}

      iex> teams = [%{name: "a", depends_on: ["b"]}, %{name: "b", depends_on: ["a"]}]
      iex> Cortex.Orchestration.DAG.build_tiers(teams)
      {:error, :cycle}

  """
  @spec build_tiers([team()]) ::
          {:ok, [tier()]} | {:error, :cycle} | {:error, :unknown_dependency, String.t()}
  def build_tiers([]), do: {:ok, []}

  def build_tiers(teams) do
    team_names = MapSet.new(teams, & &1.name)

    with :ok <- validate_dependencies(teams, team_names) do
      kahns_algorithm(teams, team_names)
    end
  end

  @doc """
  Returns the list of direct dependency names for a given team.

  Looks up the team by name in the provided list and returns its
  `depends_on` field. Returns an empty list if the team is not found.

  ## Parameters

    - `team_name` — the name of the team to look up
    - `teams` — the list of team maps/structs

  ## Examples

      iex> teams = [
      ...>   %{name: "frontend", depends_on: ["backend", "auth"]},
      ...>   %{name: "backend", depends_on: []}
      ...> ]
      iex> Cortex.Orchestration.DAG.dependencies_for("frontend", teams)
      ["backend", "auth"]
      iex> Cortex.Orchestration.DAG.dependencies_for("backend", teams)
      []

  """
  @spec dependencies_for(String.t(), [team()]) :: [String.t()]
  def dependencies_for(team_name, teams) do
    case Enum.find(teams, fn t -> t.name == team_name end) do
      nil -> []
      team -> team.depends_on
    end
  end

  @doc """
  Returns the list of team names that directly depend on the given team.

  Scans all teams and returns those whose `depends_on` includes `team_name`.

  ## Parameters

    - `team_name` — the name of the team to find dependents of
    - `teams` — the list of team maps/structs

  ## Examples

      iex> teams = [
      ...>   %{name: "backend", depends_on: []},
      ...>   %{name: "frontend", depends_on: ["backend"]},
      ...>   %{name: "devops", depends_on: ["backend"]}
      ...> ]
      iex> Cortex.Orchestration.DAG.dependents_of("backend", teams)
      ["devops", "frontend"]

  """
  @spec dependents_of(String.t(), [team()]) :: [String.t()]
  def dependents_of(team_name, teams) do
    teams
    |> Enum.filter(fn t -> team_name in t.depends_on end)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  # --- Private ---

  @spec validate_dependencies([team()], MapSet.t()) ::
          :ok | {:error, :unknown_dependency, String.t()}
  defp validate_dependencies(teams, team_names) do
    teams
    |> Enum.flat_map(fn t -> t.depends_on end)
    |> Enum.find(fn dep -> not MapSet.member?(team_names, dep) end)
    |> case do
      nil -> :ok
      unknown -> {:error, :unknown_dependency, unknown}
    end
  end

  @spec kahns_algorithm([team()], MapSet.t()) :: {:ok, [tier()]} | {:error, :cycle}
  defp kahns_algorithm(teams, _team_names) do
    # Build adjacency list: dependency -> list of dependents
    adjacency =
      Enum.reduce(teams, %{}, fn team, acc ->
        Enum.reduce(team.depends_on, acc, fn dep, inner_acc ->
          Map.update(inner_acc, dep, [team.name], &[team.name | &1])
        end)
      end)

    # Build in-degree map: team_name -> number of dependencies
    in_degree =
      Map.new(teams, fn team -> {team.name, length(team.depends_on)} end)

    # Seed queue with teams that have zero in-degree
    initial_queue =
      in_degree
      |> Enum.filter(fn {_name, deg} -> deg == 0 end)
      |> Enum.map(fn {name, _deg} -> name end)
      |> Enum.sort()

    process_tiers(initial_queue, in_degree, adjacency, [], 0, map_size(in_degree))
  end

  @spec process_tiers(
          [String.t()],
          %{String.t() => non_neg_integer()},
          %{String.t() => [String.t()]},
          [tier()],
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, [tier()]} | {:error, :cycle}
  defp process_tiers([], _in_degree, _adjacency, tiers, processed, total) do
    if processed == total do
      {:ok, Enum.reverse(tiers)}
    else
      {:error, :cycle}
    end
  end

  defp process_tiers(queue, in_degree, adjacency, tiers, processed, total) do
    tier = Enum.sort(queue)

    # Decrement in-degree for each dependent of each team in this tier
    updated_in_degree =
      Enum.reduce(tier, in_degree, fn team_name, acc ->
        dependents = Map.get(adjacency, team_name, [])

        Enum.reduce(dependents, acc, fn dep, inner_acc ->
          Map.update!(inner_acc, dep, &(&1 - 1))
        end)
      end)

    # Next queue: teams whose in-degree just became 0
    next_queue =
      updated_in_degree
      |> Enum.filter(fn {name, deg} -> deg == 0 and name not in tier end)
      |> Enum.reject(fn {name, _deg} ->
        # Reject teams already processed in earlier tiers
        Enum.any?(tiers, fn prev_tier -> name in prev_tier end)
      end)
      |> Enum.map(fn {name, _deg} -> name end)
      |> Enum.sort()

    process_tiers(
      next_queue,
      updated_in_degree,
      adjacency,
      [tier | tiers],
      processed + length(tier),
      total
    )
  end
end
