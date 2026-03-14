defmodule Cortex.Orchestration.DAGTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.DAG

  describe "build_tiers/1" do
    test "empty teams list returns empty tiers" do
      assert {:ok, []} = DAG.build_tiers([])
    end

    test "single team with no dependencies returns one tier" do
      teams = [%{name: "solo", depends_on: []}]
      assert {:ok, [["solo"]]} = DAG.build_tiers(teams)
    end

    test "multiple teams with no dependencies all land in first tier" do
      teams = [
        %{name: "alpha", depends_on: []},
        %{name: "beta", depends_on: []},
        %{name: "gamma", depends_on: []}
      ]

      assert {:ok, [tier]} = DAG.build_tiers(teams)
      assert tier == ["alpha", "beta", "gamma"]
    end

    test "linear chain produces one team per tier" do
      teams = [
        %{name: "a", depends_on: []},
        %{name: "b", depends_on: ["a"]},
        %{name: "c", depends_on: ["b"]}
      ]

      assert {:ok, [["a"], ["b"], ["c"]]} = DAG.build_tiers(teams)
    end

    test "diamond dependency produces three tiers" do
      teams = [
        %{name: "a", depends_on: []},
        %{name: "b", depends_on: ["a"]},
        %{name: "c", depends_on: ["a"]},
        %{name: "d", depends_on: ["b", "c"]}
      ]

      assert {:ok, [["a"], tier2, ["d"]]} = DAG.build_tiers(teams)
      assert tier2 == ["b", "c"]
    end

    test "example from spec: backend, frontend, devops, integration" do
      teams = [
        %{name: "backend", depends_on: []},
        %{name: "frontend", depends_on: ["backend"]},
        %{name: "devops", depends_on: ["backend"]},
        %{name: "integration", depends_on: ["frontend", "devops"]}
      ]

      assert {:ok, [["backend"], tier2, ["integration"]]} = DAG.build_tiers(teams)
      assert tier2 == ["devops", "frontend"]
    end

    test "cycle detection returns error" do
      teams = [
        %{name: "a", depends_on: ["b"]},
        %{name: "b", depends_on: ["a"]}
      ]

      assert {:error, :cycle} = DAG.build_tiers(teams)
    end

    test "self-reference returns cycle error" do
      teams = [%{name: "a", depends_on: ["a"]}]

      assert {:error, :cycle} = DAG.build_tiers(teams)
    end

    test "three-node cycle returns error" do
      teams = [
        %{name: "a", depends_on: ["c"]},
        %{name: "b", depends_on: ["a"]},
        %{name: "c", depends_on: ["b"]}
      ]

      assert {:error, :cycle} = DAG.build_tiers(teams)
    end

    test "unknown dependency returns error with name" do
      teams = [
        %{name: "a", depends_on: ["nonexistent"]}
      ]

      assert {:error, :unknown_dependency, "nonexistent"} = DAG.build_tiers(teams)
    end

    test "unknown dependency detected among valid dependencies" do
      teams = [
        %{name: "a", depends_on: []},
        %{name: "b", depends_on: ["a", "ghost"]}
      ]

      assert {:error, :unknown_dependency, "ghost"} = DAG.build_tiers(teams)
    end

    test "teams within each tier are sorted alphabetically" do
      teams = [
        %{name: "zebra", depends_on: []},
        %{name: "apple", depends_on: []},
        %{name: "mango", depends_on: []}
      ]

      assert {:ok, [["apple", "mango", "zebra"]]} = DAG.build_tiers(teams)
    end

    test "complex graph with mixed parallelism" do
      # Graph:
      #   a (no deps)
      #   b (no deps)
      #   c -> a
      #   d -> a, b
      #   e -> c, d
      #   f -> b
      teams = [
        %{name: "a", depends_on: []},
        %{name: "b", depends_on: []},
        %{name: "c", depends_on: ["a"]},
        %{name: "d", depends_on: ["a", "b"]},
        %{name: "e", depends_on: ["c", "d"]},
        %{name: "f", depends_on: ["b"]}
      ]

      assert {:ok, tiers} = DAG.build_tiers(teams)
      assert length(tiers) == 3

      assert Enum.at(tiers, 0) == ["a", "b"]
      assert Enum.at(tiers, 1) == ["c", "d", "f"]
      assert Enum.at(tiers, 2) == ["e"]
    end

    test "wide graph: many teams depending on single root" do
      root = %{name: "root", depends_on: []}

      leaves =
        for i <- 1..10 do
          %{
            name: "leaf_#{String.pad_leading(Integer.to_string(i), 2, "0")}",
            depends_on: ["root"]
          }
        end

      teams = [root | leaves]
      assert {:ok, [["root"], leaf_tier]} = DAG.build_tiers(teams)
      assert length(leaf_tier) == 10
    end

    test "deep chain: 10 sequential teams" do
      teams =
        for i <- 0..9 do
          deps = if i == 0, do: [], else: ["t#{i - 1}"]
          %{name: "t#{i}", depends_on: deps}
        end

      assert {:ok, tiers} = DAG.build_tiers(teams)
      assert length(tiers) == 10

      Enum.each(Enum.with_index(tiers), fn {tier, idx} ->
        assert tier == ["t#{idx}"]
      end)
    end

    test "partial cycle with some valid teams returns error" do
      teams = [
        %{name: "a", depends_on: []},
        %{name: "b", depends_on: ["c"]},
        %{name: "c", depends_on: ["b"]}
      ]

      assert {:error, :cycle} = DAG.build_tiers(teams)
    end

    test "input order does not affect tier assignment" do
      teams_v1 = [
        %{name: "c", depends_on: ["a"]},
        %{name: "a", depends_on: []},
        %{name: "b", depends_on: ["a"]}
      ]

      teams_v2 = [
        %{name: "a", depends_on: []},
        %{name: "b", depends_on: ["a"]},
        %{name: "c", depends_on: ["a"]}
      ]

      assert {:ok, tiers1} = DAG.build_tiers(teams_v1)
      assert {:ok, tiers2} = DAG.build_tiers(teams_v2)
      assert tiers1 == tiers2
    end
  end

  describe "dependencies_for/2" do
    setup do
      teams = [
        %{name: "backend", depends_on: []},
        %{name: "frontend", depends_on: ["backend", "auth"]},
        %{name: "auth", depends_on: []}
      ]

      %{teams: teams}
    end

    test "returns direct dependencies for a team", %{teams: teams} do
      assert DAG.dependencies_for("frontend", teams) == ["backend", "auth"]
    end

    test "returns empty list for team with no dependencies", %{teams: teams} do
      assert DAG.dependencies_for("backend", teams) == []
    end

    test "returns empty list for unknown team name", %{teams: teams} do
      assert DAG.dependencies_for("nonexistent", teams) == []
    end
  end

  describe "dependents_of/2" do
    setup do
      teams = [
        %{name: "backend", depends_on: []},
        %{name: "frontend", depends_on: ["backend"]},
        %{name: "devops", depends_on: ["backend"]},
        %{name: "integration", depends_on: ["frontend", "devops"]}
      ]

      %{teams: teams}
    end

    test "returns teams that depend on the given team", %{teams: teams} do
      assert DAG.dependents_of("backend", teams) == ["devops", "frontend"]
    end

    test "returns single dependent", %{teams: teams} do
      assert DAG.dependents_of("frontend", teams) == ["integration"]
    end

    test "returns empty list for leaf team with no dependents", %{teams: teams} do
      assert DAG.dependents_of("integration", teams) == []
    end

    test "returns empty list for unknown team name", %{teams: teams} do
      assert DAG.dependents_of("nonexistent", teams) == []
    end

    test "results are sorted alphabetically", %{teams: teams} do
      result = DAG.dependents_of("backend", teams)
      assert result == Enum.sort(result)
    end
  end
end
