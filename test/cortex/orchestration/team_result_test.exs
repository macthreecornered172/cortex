defmodule Cortex.Orchestration.TeamResultTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.TeamResult

  describe "struct creation" do
    test "creates a minimal result with required fields only" do
      result = %TeamResult{team: "backend", status: :success}

      assert result.team == "backend"
      assert result.status == :success
      assert result.result == nil
      assert result.cost_usd == nil
      assert result.num_turns == nil
      assert result.duration_ms == nil
      assert result.session_id == nil
    end

    test "creates a fully populated result" do
      result = %TeamResult{
        team: "frontend",
        status: :success,
        result: "All tasks completed",
        cost_usd: 1.23,
        num_turns: 10,
        duration_ms: 45_000,
        session_id: "sess-abc-123"
      }

      assert result.team == "frontend"
      assert result.status == :success
      assert result.result == "All tasks completed"
      assert result.cost_usd == 1.23
      assert result.num_turns == 10
      assert result.duration_ms == 45_000
      assert result.session_id == "sess-abc-123"
    end

    test "supports :error status" do
      result = %TeamResult{team: "devops", status: :error, result: "Build failed"}

      assert result.status == :error
      assert result.result == "Build failed"
    end

    test "supports :timeout status" do
      result = %TeamResult{team: "integration", status: :timeout}

      assert result.status == :timeout
    end

    test "raises on missing :team field" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(TeamResult, status: :success)
      end
    end

    test "raises on missing :status field" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(TeamResult, team: "backend")
      end
    end

    test "raises when both required fields are missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(TeamResult, result: "something")
      end
    end
  end
end
