defmodule Cortex.Provider.ResolverTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.Config.{Defaults, Lead, Team}
  alias Cortex.Provider.Resolver

  # Helper to build a minimal Team struct
  defp build_team(overrides \\ %{}) do
    base = %Team{
      name: "test-team",
      lead: %Lead{role: "Test Lead"},
      tasks: [%Cortex.Orchestration.Config.Task{summary: "do stuff"}]
    }

    Map.merge(base, overrides)
  end

  describe "resolve/2" do
    test "returns Provider.CLI when defaults has provider: :cli" do
      team = build_team()
      defaults = %Defaults{provider: :cli}

      assert {:ok, Cortex.Provider.CLI} = Resolver.resolve(team, defaults)
    end

    test "returns Provider.HTTP when defaults has provider: :http" do
      team = build_team()
      defaults = %Defaults{provider: :http}

      assert {:ok, Cortex.Provider.HTTP} = Resolver.resolve(team, defaults)
    end

    test "returns Provider.External when defaults has provider: :external" do
      team = build_team()
      defaults = %Defaults{provider: :external}

      assert {:ok, Cortex.Provider.External} = Resolver.resolve(team, defaults)
    end

    test "defaults to Provider.CLI when no provider is set" do
      team = build_team()
      # Defaults struct defaults to provider: :cli
      defaults = %Defaults{}

      assert {:ok, Cortex.Provider.CLI} = Resolver.resolve(team, defaults)
    end

    test "returns error for unknown provider atom" do
      team = build_team()
      defaults = %Defaults{provider: :bogus}

      assert {:error, {:unknown_provider, :bogus}} = Resolver.resolve(team, defaults)
    end

    test "team-level provider overrides defaults-level provider" do
      # Simulate a team with a :provider field by merging into the struct map.
      # Once the Config Engineer adds :provider to Team, this will use the
      # struct field directly.
      team = build_team() |> Map.put(:provider, :external)
      defaults = %Defaults{provider: :cli}

      assert {:ok, Cortex.Provider.External} = Resolver.resolve(team, defaults)
    end

    test "falls back to defaults when team has no provider field" do
      team = build_team()
      defaults = %Defaults{provider: :http}

      assert {:ok, Cortex.Provider.HTTP} = Resolver.resolve(team, defaults)
    end

    test "team-level nil provider falls back to defaults" do
      team = build_team() |> Map.put(:provider, nil)
      defaults = %Defaults{provider: :external}

      assert {:ok, Cortex.Provider.External} = Resolver.resolve(team, defaults)
    end
  end

  describe "resolve!/2" do
    test "returns module directly for valid provider" do
      team = build_team()
      defaults = %Defaults{provider: :cli}

      assert Cortex.Provider.CLI = Resolver.resolve!(team, defaults)
    end

    test "raises ArgumentError for unknown provider" do
      team = build_team()
      defaults = %Defaults{provider: :bogus}

      assert_raise ArgumentError, ~r/unknown provider: :bogus/, fn ->
        Resolver.resolve!(team, defaults)
      end
    end
  end
end
