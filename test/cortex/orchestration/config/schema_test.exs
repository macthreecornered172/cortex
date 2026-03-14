defmodule Cortex.Orchestration.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.Config
  alias Cortex.Orchestration.Config.{Defaults, Lead, Member, Task, Team}

  describe "Config struct" do
    test "enforces required keys :name and :teams" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Config, [])
      end
    end

    test "creates with required fields and default values" do
      config = %Config{name: "test-project", teams: []}
      assert config.name == "test-project"
      assert config.teams == []
      assert config.defaults == %Defaults{}
    end

    test "defaults struct has expected default values" do
      defaults = %Defaults{}
      assert defaults.model == "sonnet"
      assert defaults.max_turns == 200
      assert defaults.permission_mode == "acceptEdits"
      assert defaults.timeout_minutes == 30
    end
  end

  describe "Lead struct" do
    test "enforces required key :role" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Lead, [])
      end
    end

    test "creates with role and optional model" do
      lead = %Lead{role: "Backend Lead", model: "opus"}
      assert lead.role == "Backend Lead"
      assert lead.model == "opus"
    end

    test "model defaults to nil" do
      lead = %Lead{role: "Frontend Lead"}
      assert is_nil(lead.model)
    end
  end

  describe "Member struct" do
    test "enforces required key :role" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Member, [])
      end
    end

    test "creates with role and optional focus" do
      member = %Member{role: "API Engineer", focus: "REST endpoints"}
      assert member.role == "API Engineer"
      assert member.focus == "REST endpoints"
    end

    test "focus defaults to nil" do
      member = %Member{role: "Tester"}
      assert is_nil(member.focus)
    end
  end

  describe "Task struct" do
    test "enforces required key :summary" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Task, [])
      end
    end

    test "creates with summary and optional fields" do
      task = %Task{
        summary: "Build REST API",
        details: "Create endpoints for users",
        deliverables: ["src/api/"],
        verify: "go build ./..."
      }

      assert task.summary == "Build REST API"
      assert task.details == "Create endpoints for users"
      assert task.deliverables == ["src/api/"]
      assert task.verify == "go build ./..."
    end

    test "optional fields default correctly" do
      task = %Task{summary: "Do something"}
      assert is_nil(task.details)
      assert task.deliverables == []
      assert is_nil(task.verify)
    end
  end

  describe "Team struct" do
    test "enforces required keys :name, :lead, :tasks" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Team, [])
      end
    end

    test "creates a full team" do
      team = %Team{
        name: "backend",
        lead: %Lead{role: "Backend Lead", model: "opus"},
        members: [%Member{role: "API Engineer", focus: "REST"}],
        tasks: [%Task{summary: "Build API", verify: "go test ./..."}],
        depends_on: ["shared"],
        context: "Tech stack: Go, Postgres"
      }

      assert team.name == "backend"
      assert team.lead.role == "Backend Lead"
      assert length(team.members) == 1
      assert length(team.tasks) == 1
      assert team.depends_on == ["shared"]
      assert team.context == "Tech stack: Go, Postgres"
    end

    test "optional fields default correctly" do
      team = %Team{
        name: "minimal",
        lead: %Lead{role: "Lead"},
        tasks: [%Task{summary: "Do work"}]
      }

      assert team.members == []
      assert team.depends_on == []
      assert is_nil(team.context)
    end
  end
end
