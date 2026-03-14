defmodule Cortex.Orchestration.FileUtilsTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.FileUtils

  @moduletag :orchestration

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "cortex_file_utils_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "atomic_write/2" do
    test "writes content to the target file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.json")
      assert :ok = FileUtils.atomic_write(path, ~s({"hello": "world"}))
      assert File.read!(path) == ~s({"hello": "world"})
    end

    test "overwrites existing file content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.json")
      File.write!(path, "old content")

      assert :ok = FileUtils.atomic_write(path, "new content")
      assert File.read!(path) == "new content"
    end

    test "does not leave .tmp file behind on success", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.json")
      assert :ok = FileUtils.atomic_write(path, "content")
      refute File.exists?(path <> ".tmp")
    end

    test "returns error when parent directory does not exist", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nonexistent", "subdir", "test.json"])
      assert {:error, _reason} = FileUtils.atomic_write(path, "content")
    end

    test "handles empty content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.json")
      assert :ok = FileUtils.atomic_write(path, "")
      assert File.read!(path) == ""
    end

    test "handles large content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "large.json")
      content = String.duplicate("x", 1_000_000)
      assert :ok = FileUtils.atomic_write(path, content)
      assert File.read!(path) == content
    end

    test "content is fully written (not partial)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "integrity.json")
      content = Jason.encode!(%{"data" => List.duplicate("value", 100)}, pretty: true)
      assert :ok = FileUtils.atomic_write(path, content)

      # Verify the file is valid JSON (no partial writes)
      assert {:ok, _} = Jason.decode(File.read!(path))
    end
  end
end
