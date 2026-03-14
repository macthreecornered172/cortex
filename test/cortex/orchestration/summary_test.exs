defmodule Cortex.Orchestration.SummaryTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.Summary
  alias Cortex.Orchestration.State
  alias Cortex.Orchestration.TeamState

  @moduletag :orchestration

  # -- format/1 ----------------------------------------------------------------

  describe "format/1" do
    test "formats a state with multiple completed teams" do
      state = %State{
        project: "my-project",
        teams: %{
          "backend" => %TeamState{
            status: "done",
            cost_usd: 1.20,
            duration_ms: 252_000
          },
          "frontend" => %TeamState{
            status: "done",
            cost_usd: 0.85,
            duration_ms: 185_000
          }
        }
      }

      output = Summary.format(state)

      assert output =~ "Cortex: my-project -- Complete"
      assert output =~ "backend"
      assert output =~ "frontend"
      assert output =~ "done"
      assert output =~ "$1.20"
      assert output =~ "$0.85"
      assert output =~ "4m 12s"
      assert output =~ "3m 05s"
      # Total row
      assert output =~ "$2.05"
      assert output =~ "Total"
    end

    test "formats with a failed team" do
      state = %State{
        project: "broken",
        teams: %{
          "api" => %TeamState{status: "done", cost_usd: 0.50, duration_ms: 30_000},
          "deploy" => %TeamState{status: "failed", cost_usd: 0.10, duration_ms: 5_000}
        }
      }

      output = Summary.format(state)
      assert output =~ "Failed"
      assert output =~ "failed"
      assert output =~ "done"
    end

    test "formats with zero cost" do
      state = %State{
        project: "free-run",
        teams: %{
          "solo" => %TeamState{status: "done", cost_usd: 0.0, duration_ms: 1_000}
        }
      }

      output = Summary.format(state)
      assert output =~ "$0.00"
    end

    test "formats with nil cost and duration" do
      state = %State{
        project: "partial",
        teams: %{
          "pending-team" => %TeamState{status: "pending"}
        }
      }

      output = Summary.format(state)
      assert output =~ "pending"
      assert output =~ "--"
    end

    test "formats empty teams" do
      state = %State{project: "empty", teams: %{}}
      output = Summary.format(state)
      assert output =~ "Cortex: empty -- Empty"
      assert output =~ "Total"
    end

    test "shows Running status when a team is running" do
      state = %State{
        project: "in-progress",
        teams: %{
          "alpha" => %TeamState{status: "running", cost_usd: 0.10, duration_ms: 5_000}
        }
      }

      output = Summary.format(state)
      assert output =~ "Running"
    end
  end

  # -- format_duration/1 -------------------------------------------------------

  describe "format_duration/1" do
    test "nil returns --" do
      assert Summary.format_duration(nil) == "--"
    end

    test "0 returns 0s" do
      assert Summary.format_duration(0) == "0s"
    end

    test "seconds only" do
      assert Summary.format_duration(5_000) == "5s"
      assert Summary.format_duration(45_000) == "45s"
    end

    test "minutes and seconds" do
      assert Summary.format_duration(60_000) == "1m 00s"
      assert Summary.format_duration(65_000) == "1m 05s"
      assert Summary.format_duration(252_000) == "4m 12s"
    end

    test "hours, minutes, and seconds" do
      assert Summary.format_duration(3_600_000) == "1h 0m 00s"
      assert Summary.format_duration(5_025_000) == "1h 23m 45s"
    end

    test "large durations" do
      # 2 hours, 30 minutes, 15 seconds
      ms = (2 * 3_600 + 30 * 60 + 15) * 1_000
      assert Summary.format_duration(ms) == "2h 30m 15s"
    end
  end

  # -- format_cost/1 -----------------------------------------------------------

  describe "format_cost/1" do
    test "nil returns --" do
      assert Summary.format_cost(nil) == "--"
    end

    test "zero cost" do
      assert Summary.format_cost(0.0) == "$0.00"
    end

    test "typical costs" do
      assert Summary.format_cost(1.5) == "$1.50"
      assert Summary.format_cost(0.05) == "$0.05"
      assert Summary.format_cost(12.345) == "$12.35"
    end

    test "integer cost" do
      assert Summary.format_cost(3) == "$3.00"
    end
  end
end
