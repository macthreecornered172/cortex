defmodule Cortex.Orchestration.InjectionTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.Injection
  alias Cortex.Orchestration.Config.{Defaults, Lead, Member, Task, Team}
  alias Cortex.Orchestration.{State, TeamState}

  @defaults %Defaults{
    model: "sonnet",
    max_turns: 200,
    permission_mode: "acceptEdits",
    timeout_minutes: 30
  }

  @empty_state %State{project: "test-project", teams: %{}}

  defp solo_team(attrs \\ %{}) do
    base = %Team{
      name: "backend",
      lead: %Lead{role: "Backend Lead"},
      members: [],
      tasks: [
        %Task{
          summary: "Build REST API",
          details: "Create endpoints for users and posts.",
          deliverables: ["src/api/", "src/models/"],
          verify: "go build ./..."
        }
      ],
      depends_on: [],
      context: "Tech stack: Go, Chi router, Postgres"
    }

    struct(base, attrs)
  end

  defp team_with_members(attrs \\ %{}) do
    base = %Team{
      name: "fullstack",
      lead: %Lead{role: "Fullstack Lead", model: "opus"},
      members: [
        %Member{role: "API Engineer", focus: "REST endpoints, validation"},
        %Member{role: "DB Engineer", focus: "Schema design, migrations"}
      ],
      tasks: [
        %Task{
          summary: "Build REST API",
          details: "Create endpoints for users and posts.",
          deliverables: ["src/api/"],
          verify: "go build ./..."
        },
        %Task{
          summary: "Set up database",
          details: "Create schema and migrations.",
          deliverables: ["db/migrations/"],
          verify: "mix ecto.migrate"
        }
      ],
      depends_on: [],
      context: "Tech stack: Elixir, Phoenix, Postgres"
    }

    struct(base, attrs)
  end

  describe "build_prompt/4 — solo agent (no members)" do
    test "includes all sections in correct order" do
      prompt = Injection.build_prompt(solo_team(), "my-project", @empty_state, @defaults)

      assert prompt =~ "You are: Backend Lead"
      assert prompt =~ "Project: my-project"
      assert prompt =~ "## Technical Context"
      assert prompt =~ "Tech stack: Go, Chi router, Postgres"
      assert prompt =~ "## Your Tasks"
      assert prompt =~ "### Task: Build REST API"
      assert prompt =~ "Create endpoints for users and posts."
      assert prompt =~ "Deliverables: src/api/, src/models/"
      assert prompt =~ "Verify: go build ./..."
      assert prompt =~ "## Context from Previous Teams"
      assert prompt =~ "No previous team results available."
      assert prompt =~ "## Instructions"
      assert prompt =~ "Work through your tasks in order."
    end

    test "does NOT include Your Team section" do
      prompt = Injection.build_prompt(solo_team(), "my-project", @empty_state, @defaults)

      refute prompt =~ "## Your Team"
      refute prompt =~ "team lead"
    end
  end

  describe "build_prompt/4 — team lead (with members)" do
    test "includes Your Team section with member roles and focuses" do
      prompt =
        Injection.build_prompt(team_with_members(), "my-project", @empty_state, @defaults)

      assert prompt =~ "## Your Team"
      assert prompt =~ "You are the team lead."
      assert prompt =~ "- **API Engineer**: REST endpoints, validation"
      assert prompt =~ "- **DB Engineer**: Schema design, migrations"
      assert prompt =~ "Coordinate your team"
    end

    test "includes all other sections as well" do
      prompt =
        Injection.build_prompt(team_with_members(), "my-project", @empty_state, @defaults)

      assert prompt =~ "You are: Fullstack Lead"
      assert prompt =~ "## Technical Context"
      assert prompt =~ "## Your Tasks"
      assert prompt =~ "## Context from Previous Teams"
      assert prompt =~ "## Instructions"
    end
  end

  describe "build_prompt/4 — dependencies" do
    test "includes context from completed dependencies" do
      team = solo_team(%{depends_on: ["auth", "infra"]})

      state = %State{
        project: "test-project",
        teams: %{
          "auth" => %TeamState{
            status: "done",
            result_summary: "Built OAuth2 flow with JWT tokens."
          },
          "infra" => %TeamState{
            status: "done",
            result_summary: "Provisioned AWS ECS cluster."
          }
        }
      }

      prompt = Injection.build_prompt(team, "my-project", state, @defaults)

      assert prompt =~ "## Context from Previous Teams"
      assert prompt =~ "### auth"
      assert prompt =~ "Built OAuth2 flow with JWT tokens."
      assert prompt =~ "### infra"
      assert prompt =~ "Provisioned AWS ECS cluster."
      refute prompt =~ "No previous team results available."
    end

    test "handles dependencies with no results yet (pending/running)" do
      team = solo_team(%{depends_on: ["auth"]})

      state = %State{
        project: "test-project",
        teams: %{
          "auth" => %TeamState{status: "running", result_summary: nil}
        }
      }

      prompt = Injection.build_prompt(team, "my-project", state, @defaults)

      assert prompt =~ "No previous team results available."
      refute prompt =~ "### auth"
    end

    test "handles dependencies not present in state at all" do
      team = solo_team(%{depends_on: ["missing-team"]})

      prompt = Injection.build_prompt(team, "my-project", @empty_state, @defaults)

      assert prompt =~ "No previous team results available."
    end

    test "includes only completed dependencies, skips failed ones" do
      team = solo_team(%{depends_on: ["auth", "broken"]})

      state = %State{
        project: "test-project",
        teams: %{
          "auth" => %TeamState{status: "done", result_summary: "Auth is ready."},
          "broken" => %TeamState{status: "failed", result_summary: "Crashed."}
        }
      }

      prompt = Injection.build_prompt(team, "my-project", state, @defaults)

      assert prompt =~ "### auth"
      assert prompt =~ "Auth is ready."
      refute prompt =~ "### broken"
    end
  end

  describe "build_prompt/4 — team with no depends_on" do
    test "shows no previous team results message" do
      prompt = Injection.build_prompt(solo_team(), "my-project", @empty_state, @defaults)

      assert prompt =~ "## Context from Previous Teams"
      assert prompt =~ "No previous team results available."
    end
  end

  describe "build_prompt/4 — empty/nil context" do
    test "omits Technical Context section when context is nil" do
      team = solo_team(%{context: nil})
      prompt = Injection.build_prompt(team, "my-project", @empty_state, @defaults)

      refute prompt =~ "## Technical Context"
    end

    test "omits Technical Context section when context is empty string" do
      team = solo_team(%{context: ""})
      prompt = Injection.build_prompt(team, "my-project", @empty_state, @defaults)

      refute prompt =~ "## Technical Context"
    end
  end

  describe "build_prompt/4 — tasks with nil details or deliverables" do
    test "handles task with nil details" do
      team =
        solo_team(%{
          tasks: [
            %Task{
              summary: "Do the thing",
              details: nil,
              deliverables: ["out/"],
              verify: "make test"
            }
          ]
        })

      prompt = Injection.build_prompt(team, "my-project", @empty_state, @defaults)

      assert prompt =~ "### Task: Do the thing"
      assert prompt =~ "Deliverables: out/"
      assert prompt =~ "Verify: make test"
    end

    test "handles task with nil deliverables (uses default empty list)" do
      team =
        solo_team(%{
          tasks: [
            %Task{
              summary: "Do the thing",
              details: "Some details.",
              deliverables: [],
              verify: nil
            }
          ]
        })

      prompt = Injection.build_prompt(team, "my-project", @empty_state, @defaults)

      assert prompt =~ "### Task: Do the thing"
      assert prompt =~ "Some details."
      refute prompt =~ "Deliverables:"
      refute prompt =~ "Verify:"
    end

    test "handles task with empty details string" do
      team =
        solo_team(%{
          tasks: [
            %Task{summary: "Do it", details: "", deliverables: ["a.txt"], verify: "echo ok"}
          ]
        })

      prompt = Injection.build_prompt(team, "my-project", @empty_state, @defaults)

      assert prompt =~ "### Task: Do it"
      assert prompt =~ "Deliverables: a.txt"
    end
  end

  describe "build_model/2" do
    test "uses team lead model when set" do
      team = %Team{
        name: "test",
        lead: %Lead{role: "Lead", model: "opus"},
        tasks: [%Task{summary: "task"}]
      }

      assert Injection.build_model(team, @defaults) == "opus"
    end

    test "falls back to defaults when team lead model is nil" do
      team = %Team{
        name: "test",
        lead: %Lead{role: "Lead", model: nil},
        tasks: [%Task{summary: "task"}]
      }

      assert Injection.build_model(team, @defaults) == "sonnet"
    end

    test "falls back to defaults when lead has no model field" do
      team = %Team{
        name: "test",
        lead: %Lead{role: "Lead"},
        tasks: [%Task{summary: "task"}]
      }

      assert Injection.build_model(team, @defaults) == "sonnet"
    end
  end

  describe "build_max_turns/1" do
    test "returns defaults max_turns value" do
      assert Injection.build_max_turns(@defaults) == 200
    end

    test "returns custom max_turns value" do
      custom = %Defaults{max_turns: 50, model: "sonnet", permission_mode: "acceptEdits"}
      assert Injection.build_max_turns(custom) == 50
    end
  end

  describe "build_permission_mode/1" do
    test "returns defaults permission_mode value" do
      assert Injection.build_permission_mode(@defaults) == "acceptEdits"
    end

    test "returns custom permission_mode value" do
      custom = %Defaults{permission_mode: "bypassPermissions", model: "sonnet", max_turns: 200}
      assert Injection.build_permission_mode(custom) == "bypassPermissions"
    end
  end
end
