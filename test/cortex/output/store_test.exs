defmodule Cortex.Output.StoreTest do
  use ExUnit.Case, async: true

  alias Cortex.Output.Store

  describe "build_key/2" do
    test "builds a key from run_id and team_name" do
      assert Store.build_key("run-abc-123", "strength-coach") ==
               "runs/run-abc-123/teams/strength-coach/output"
    end
  end
end
