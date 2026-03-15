defmodule Cortex.Orchestration.InjectionInboxTest do
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
          details: "Create endpoints.",
          deliverables: ["src/api/"],
          verify: "go build ./..."
        }
      ],
      depends_on: [],
      context: "Tech stack: Go"
    }

    struct(base, attrs)
  end

  defp team_with_members(attrs \\ %{}) do
    base = %Team{
      name: "fullstack",
      lead: %Lead{role: "Fullstack Lead", model: "opus"},
      members: [
        %Member{role: "API Engineer", focus: "REST endpoints"},
        %Member{role: "DB Engineer", focus: "Schema design"}
      ],
      tasks: [
        %Task{
          summary: "Build REST API",
          details: "Create endpoints.",
          deliverables: ["src/api/"],
          verify: "go build ./..."
        }
      ],
      depends_on: [],
      context: "Tech stack: Elixir"
    }

    struct(base, attrs)
  end

  describe "solo agent prompt inbox section" do
    test "includes Message Inbox section" do
      prompt = Injection.build_prompt(solo_team(), "my-project", @empty_state, @defaults)
      assert prompt =~ "## Message Inbox"
    end

    test "includes inbox path with correct team name" do
      prompt = Injection.build_prompt(solo_team(), "my-project", @empty_state, @defaults)
      assert prompt =~ ".cortex/messages/backend/inbox.json"
    end

    test "includes outbox path with correct team name" do
      prompt = Injection.build_prompt(solo_team(), "my-project", @empty_state, @defaults)
      assert prompt =~ ".cortex/messages/backend/outbox.json"
    end

    test "includes /loop instruction" do
      prompt = Injection.build_prompt(solo_team(), "my-project", @empty_state, @defaults)
      assert prompt =~ "/loop 2m cat .cortex/messages/backend/inbox.json"
    end

    test "includes outbox write instructions" do
      prompt = Injection.build_prompt(solo_team(), "my-project", @empty_state, @defaults)
      assert prompt =~ ~s("from": "backend")
      assert prompt =~ ~s("to": "coordinator")
    end

    test "does NOT include team lead extra instructions" do
      prompt = Injection.build_prompt(solo_team(), "my-project", @empty_state, @defaults)
      refute prompt =~ "As team lead, check your inbox more frequently"
    end

    test "inbox section appears before Instructions section" do
      prompt = Injection.build_prompt(solo_team(), "my-project", @empty_state, @defaults)
      inbox_pos = :binary.match(prompt, "## Message Inbox") |> elem(0)
      instructions_pos = :binary.match(prompt, "## Instructions") |> elem(0)
      assert inbox_pos < instructions_pos
    end
  end

  describe "team lead prompt inbox section" do
    test "includes Message Inbox section" do
      prompt = Injection.build_prompt(team_with_members(), "my-project", @empty_state, @defaults)
      assert prompt =~ "## Message Inbox"
    end

    test "includes inbox path with correct team name" do
      prompt = Injection.build_prompt(team_with_members(), "my-project", @empty_state, @defaults)
      assert prompt =~ ".cortex/messages/fullstack/inbox.json"
    end

    test "includes /loop instruction" do
      prompt = Injection.build_prompt(team_with_members(), "my-project", @empty_state, @defaults)
      assert prompt =~ "/loop 2m cat .cortex/messages/fullstack/inbox.json"
    end

    test "includes team lead extra instructions" do
      prompt = Injection.build_prompt(team_with_members(), "my-project", @empty_state, @defaults)
      assert prompt =~ "As team lead, check your inbox more frequently"
      assert prompt =~ "coordinator may send corrections, priority changes"
    end

    test "inbox section appears before Instructions section" do
      prompt = Injection.build_prompt(team_with_members(), "my-project", @empty_state, @defaults)
      inbox_pos = :binary.match(prompt, "## Message Inbox") |> elem(0)
      instructions_pos = :binary.match(prompt, "## Instructions") |> elem(0)
      assert inbox_pos < instructions_pos
    end
  end

  describe "inbox section with different team names" do
    test "uses correct team name in paths" do
      team = solo_team(%{name: "my-special-team"})
      prompt = Injection.build_prompt(team, "my-project", @empty_state, @defaults)
      assert prompt =~ ".cortex/messages/my-special-team/inbox.json"
      assert prompt =~ ".cortex/messages/my-special-team/outbox.json"
      assert prompt =~ "/loop 2m cat .cortex/messages/my-special-team/inbox.json"
      assert prompt =~ ~s("from": "my-special-team")
    end
  end

  describe "existing prompt sections are preserved" do
    test "solo agent still includes all original sections" do
      prompt = Injection.build_prompt(solo_team(), "my-project", @empty_state, @defaults)

      assert prompt =~ "You are: Backend Lead"
      assert prompt =~ "Project: my-project"
      assert prompt =~ "## Technical Context"
      assert prompt =~ "## Your Tasks"
      assert prompt =~ "## Context from Previous Teams"
      assert prompt =~ "## Instructions"
    end

    test "team lead still includes Your Team section" do
      prompt = Injection.build_prompt(team_with_members(), "my-project", @empty_state, @defaults)

      assert prompt =~ "## Your Team"
      assert prompt =~ "You are the team lead."
    end

    test "dependencies still work with inbox section present" do
      team = solo_team(%{depends_on: ["auth"]})

      state = %State{
        project: "test-project",
        teams: %{
          "auth" => %TeamState{
            status: "done",
            result_summary: "Built OAuth2 flow."
          }
        }
      }

      prompt = Injection.build_prompt(team, "my-project", state, @defaults)

      assert prompt =~ "### auth"
      assert prompt =~ "Built OAuth2 flow."
      assert prompt =~ "## Message Inbox"
    end
  end
end
