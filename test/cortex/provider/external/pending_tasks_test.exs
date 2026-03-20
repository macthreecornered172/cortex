defmodule Cortex.Provider.External.PendingTasksTest do
  use ExUnit.Case, async: true

  alias Cortex.Provider.External.PendingTasks

  setup do
    # Use a unique table name per test to allow async: true
    table_name = :"pending_tasks_test_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      PendingTasks.start_link(
        name: :"pt_#{table_name}",
        table_name: table_name
      )

    %{server: pid}
  end

  describe "register_task/5" do
    test "inserts entry retrievable by list_pending/1", %{server: server} do
      ref = make_ref()
      :ok = PendingTasks.register_task(server, "task-1", self(), ref, "agent-1")

      pending = PendingTasks.list_pending(server)
      assert length(pending) == 1
      assert [%{task_id: "task-1", agent_id: "agent-1"}] = pending
    end

    test "registers multiple tasks", %{server: server} do
      :ok = PendingTasks.register_task(server, "task-1", self(), make_ref(), "agent-1")
      :ok = PendingTasks.register_task(server, "task-2", self(), make_ref(), "agent-2")

      pending = PendingTasks.list_pending(server)
      assert length(pending) == 2

      task_ids = Enum.map(pending, & &1.task_id) |> Enum.sort()
      assert task_ids == ["task-1", "task-2"]
    end
  end

  describe "resolve_task/3" do
    test "delivers result to caller and removes entry", %{server: server} do
      ref = make_ref()
      :ok = PendingTasks.register_task(server, "task-1", self(), ref, "agent-1")

      result = %{"status" => "completed", "result_text" => "done"}
      assert :ok = PendingTasks.resolve_task(server, "task-1", result)

      assert_receive {:task_result, ^ref, ^result}

      assert PendingTasks.list_pending(server) == []
    end

    test "returns {:error, :not_found} for unknown task_id", %{server: server} do
      assert {:error, :not_found} =
               PendingTasks.resolve_task(server, "nonexistent", %{})
    end

    test "returns {:error, :not_found} on double-resolve", %{server: server} do
      ref = make_ref()
      :ok = PendingTasks.register_task(server, "task-1", self(), ref, "agent-1")

      result = %{"status" => "completed"}
      assert :ok = PendingTasks.resolve_task(server, "task-1", result)
      assert {:error, :not_found} = PendingTasks.resolve_task(server, "task-1", result)
    end
  end

  describe "cancel_task/2" do
    test "removes entry without sending to caller", %{server: server} do
      ref = make_ref()
      :ok = PendingTasks.register_task(server, "task-1", self(), ref, "agent-1")

      assert :ok = PendingTasks.cancel_task(server, "task-1")

      refute_receive {:task_result, ^ref, _}
      assert PendingTasks.list_pending(server) == []
    end

    test "returns :ok for unknown task_id", %{server: server} do
      assert :ok = PendingTasks.cancel_task(server, "nonexistent")
    end
  end

  describe "caller :DOWN auto-cleanup" do
    test "removes pending entry when caller process dies", %{server: server} do
      ref = make_ref()

      caller =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = PendingTasks.register_task(server, "task-1", caller, ref, "agent-1")
      assert length(PendingTasks.list_pending(server)) == 1

      # Kill the caller
      Process.exit(caller, :kill)

      # Give the GenServer time to process the :DOWN message
      Process.sleep(50)

      assert PendingTasks.list_pending(server) == []
    end
  end

  describe "concurrent access" do
    test "register and resolve from multiple processes", %{server: server} do
      test_pid = self()

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            task_id = "task-#{i}"
            ref = make_ref()
            :ok = PendingTasks.register_task(server, task_id, self(), ref, "agent-#{i}")

            # Resolve from a different process
            spawn(fn ->
              result = %{"status" => "completed", "result_text" => "result-#{i}"}
              PendingTasks.resolve_task(server, task_id, result)
            end)

            assert_receive {:task_result, ^ref, result}, 1000
            send(test_pid, {:done, i, result})
          end)
        end

      Task.await_many(tasks, 5000)

      for i <- 1..10 do
        assert_receive {:done, ^i, %{"result_text" => result_text}}
        assert result_text == "result-#{i}"
      end

      assert PendingTasks.list_pending(server) == []
    end
  end

  describe "list_pending/1" do
    test "returns all pending tasks with correct fields", %{server: server} do
      :ok = PendingTasks.register_task(server, "t1", self(), make_ref(), "a1")
      :ok = PendingTasks.register_task(server, "t2", self(), make_ref(), "a2")

      pending = PendingTasks.list_pending(server)
      assert length(pending) == 2

      for entry <- pending do
        assert Map.has_key?(entry, :task_id)
        assert Map.has_key?(entry, :agent_id)
        assert Map.has_key?(entry, :dispatched_at)
        assert is_integer(entry.dispatched_at)
      end
    end

    test "returns empty list when no tasks pending", %{server: server} do
      assert PendingTasks.list_pending(server) == []
    end
  end
end
