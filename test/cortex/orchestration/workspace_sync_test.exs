defmodule Cortex.Orchestration.WorkspaceSyncTest do
  use ExUnit.Case, async: false

  alias Cortex.Orchestration.WorkspaceSync
  alias Cortex.Output.Store, as: OutputStore

  @moduletag :orchestration

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "cortex_ws_sync_test_#{:erlang.unique_integer([:positive])}"
      )

    cortex_dir = Path.join(tmp_dir, ".cortex")
    File.mkdir_p!(cortex_dir)

    store_base =
      Path.join(
        System.tmp_dir!(),
        "cortex_store_test_#{:erlang.unique_integer([:positive])}"
      )

    Application.put_env(:cortex, Cortex.Output.Store.Local, base_path: store_base)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      File.rm_rf!(store_base)
    end)

    run_id = "test-run-#{:erlang.unique_integer([:positive])}"

    %{tmp_dir: tmp_dir, cortex_dir: cortex_dir, store_base: store_base, run_id: run_id}
  end

  describe "start/1 and basic sync" do
    test "syncs new files on first tick", %{tmp_dir: tmp_dir, run_id: run_id} do
      cortex_dir = Path.join(tmp_dir, ".cortex")
      File.write!(Path.join(cortex_dir, "state.json"), ~s({"project":"test"}))

      {:ok, pid} =
        WorkspaceSync.start(
          run_id: run_id,
          workspace_path: tmp_dir,
          interval_ms: 100_000
        )

      # First tick is immediate (interval 0), give it a moment
      Process.sleep(100)

      key = OutputStore.build_workspace_key(run_id, "state.json")
      assert {:ok, ~s({"project":"test"})} = OutputStore.get(key)

      WorkspaceSync.stop(pid)
    end

    test "syncs files in subdirectories", %{
      tmp_dir: tmp_dir,
      cortex_dir: cortex_dir,
      run_id: run_id
    } do
      results_dir = Path.join(cortex_dir, "results")
      File.mkdir_p!(results_dir)
      File.write!(Path.join(results_dir, "backend.json"), ~s({"status":"done"}))

      {:ok, pid} =
        WorkspaceSync.start(run_id: run_id, workspace_path: tmp_dir, interval_ms: 100_000)

      Process.sleep(100)

      key = OutputStore.build_workspace_key(run_id, "results/backend.json")
      assert {:ok, ~s({"status":"done"})} = OutputStore.get(key)

      WorkspaceSync.stop(pid)
    end

    test "skips .tmp files", %{tmp_dir: tmp_dir, cortex_dir: cortex_dir, run_id: run_id} do
      File.write!(Path.join(cortex_dir, "state.json.tmp"), "temp")
      File.write!(Path.join(cortex_dir, "state.json"), "real")

      {:ok, pid} =
        WorkspaceSync.start(run_id: run_id, workspace_path: tmp_dir, interval_ms: 100_000)

      Process.sleep(100)

      tmp_key = OutputStore.build_workspace_key(run_id, "state.json.tmp")
      real_key = OutputStore.build_workspace_key(run_id, "state.json")

      assert {:error, :not_found} = OutputStore.get(tmp_key)
      assert {:ok, "real"} = OutputStore.get(real_key)

      WorkspaceSync.stop(pid)
    end
  end

  describe "change detection" do
    test "detects file modifications on subsequent ticks", %{
      tmp_dir: tmp_dir,
      cortex_dir: cortex_dir,
      run_id: run_id
    } do
      File.write!(Path.join(cortex_dir, "state.json"), "v1")

      {:ok, pid} =
        WorkspaceSync.start(run_id: run_id, workspace_path: tmp_dir, interval_ms: 50)

      Process.sleep(100)

      key = OutputStore.build_workspace_key(run_id, "state.json")
      assert {:ok, "v1"} = OutputStore.get(key)

      # Modify the file — need a small sleep so mtime changes
      Process.sleep(1100)
      File.write!(Path.join(cortex_dir, "state.json"), "v2")

      # Wait for next tick
      Process.sleep(150)

      assert {:ok, "v2"} = OutputStore.get(key)

      WorkspaceSync.stop(pid)
    end

    test "detects new files added after start", %{
      tmp_dir: tmp_dir,
      cortex_dir: cortex_dir,
      run_id: run_id
    } do
      {:ok, pid} =
        WorkspaceSync.start(run_id: run_id, workspace_path: tmp_dir, interval_ms: 50)

      Process.sleep(100)

      # Add a new file
      File.write!(Path.join(cortex_dir, "new_file.json"), "new")

      Process.sleep(150)

      key = OutputStore.build_workspace_key(run_id, "new_file.json")
      assert {:ok, "new"} = OutputStore.get(key)

      WorkspaceSync.stop(pid)
    end
  end

  describe "final_sync/1" do
    test "performs sync and writes manifest", %{
      tmp_dir: tmp_dir,
      cortex_dir: cortex_dir,
      run_id: run_id
    } do
      File.write!(Path.join(cortex_dir, "state.json"), ~s({"project":"test"}))
      results_dir = Path.join(cortex_dir, "results")
      File.mkdir_p!(results_dir)
      File.write!(Path.join(results_dir, "team-a.json"), ~s({"done":true}))

      {:ok, pid} =
        WorkspaceSync.start(run_id: run_id, workspace_path: tmp_dir, interval_ms: 100_000)

      Process.sleep(100)

      assert :ok = WorkspaceSync.final_sync(pid)

      # Check manifest exists
      manifest_key = OutputStore.build_workspace_key(run_id, "_manifest.json")
      assert {:ok, manifest_json} = OutputStore.get(manifest_key)
      manifest = Jason.decode!(manifest_json)

      assert manifest["run_id"] == run_id
      assert manifest["file_count"] == 2

      paths = Enum.map(manifest["files"], & &1["path"])
      assert "results/team-a.json" in paths
      assert "state.json" in paths

      WorkspaceSync.stop(pid)
    end
  end

  describe "max_file_bytes" do
    test "tails large files", %{tmp_dir: tmp_dir, cortex_dir: cortex_dir, run_id: run_id} do
      # Create a file larger than the limit
      large_content = String.duplicate("x", 1000)

      File.write!(Path.join(cortex_dir, "big.log"), large_content)

      {:ok, pid} =
        WorkspaceSync.start(
          run_id: run_id,
          workspace_path: tmp_dir,
          interval_ms: 100_000,
          max_file_bytes: 100
        )

      Process.sleep(100)

      key = OutputStore.build_workspace_key(run_id, "big.log")
      assert {:ok, content} = OutputStore.get(key)

      # Should be truncated to max_file_bytes
      assert byte_size(content) == 100

      WorkspaceSync.stop(pid)
    end
  end
end
