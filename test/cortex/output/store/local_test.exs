defmodule Cortex.Output.Store.LocalTest do
  use ExUnit.Case, async: false

  alias Cortex.Output.Store.Local

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "cortex_output_local_test_#{:erlang.unique_integer([:positive])}"
      )

    Application.put_env(:cortex, Cortex.Output.Store.Local, base_path: base)
    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base}
  end

  describe "put/3 and get/1" do
    test "roundtrips content", %{base: _base} do
      assert :ok = Local.put("runs/abc/teams/backend/output", "# Full workout plan\n...")
      assert {:ok, "# Full workout plan\n..."} = Local.get("runs/abc/teams/backend/output")
    end

    test "creates intermediate directories" do
      key = "deep/nested/path/to/output"
      assert :ok = Local.put(key, "content")
      assert {:ok, "content"} = Local.get(key)
    end

    test "overwrites existing content" do
      key = "runs/r1/teams/t1/output"
      :ok = Local.put(key, "v1")
      :ok = Local.put(key, "v2")
      assert {:ok, "v2"} = Local.get(key)
    end

    test "handles large content" do
      key = "runs/r1/teams/t1/output"
      large = String.duplicate("x", 1_000_000)
      :ok = Local.put(key, large)
      assert {:ok, ^large} = Local.get(key)
    end
  end

  describe "get/1" do
    test "returns :not_found for missing key" do
      assert {:error, :not_found} = Local.get("nonexistent/key")
    end
  end

  describe "delete/1" do
    test "removes existing content" do
      key = "runs/r1/teams/t1/output"
      :ok = Local.put(key, "content")
      assert :ok = Local.delete(key)
      assert {:error, :not_found} = Local.get(key)
    end

    test "succeeds for non-existent key" do
      assert :ok = Local.delete("nonexistent/key")
    end
  end

  describe "list_keys/1" do
    test "lists files under a prefix" do
      :ok = Local.put("runs/r1/workspace/state.json", "s")
      :ok = Local.put("runs/r1/workspace/results/backend.json", "r")
      :ok = Local.put("runs/r1/workspace/logs/run/backend.log", "l")
      :ok = Local.put("runs/r2/workspace/state.json", "other")

      assert {:ok, keys} = Local.list_keys("runs/r1/workspace/")
      assert length(keys) == 3
      assert "runs/r1/workspace/state.json" in keys
      assert "runs/r1/workspace/results/backend.json" in keys
      assert "runs/r1/workspace/logs/run/backend.log" in keys
      refute "runs/r2/workspace/state.json" in keys
    end

    test "returns empty list for nonexistent prefix" do
      assert {:ok, []} = Local.list_keys("nonexistent/prefix/")
    end

    test "returns empty list for empty directory" do
      :ok = Local.put("runs/r1/workspace/file.txt", "x")
      assert {:ok, []} = Local.list_keys("runs/r1/other/")
    end
  end
end
