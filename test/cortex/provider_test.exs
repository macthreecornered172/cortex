defmodule Cortex.ProviderTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cortex.MockProvider
  alias Cortex.Orchestration.TeamResult

  setup :verify_on_exit!

  describe "start/1 -> run/3 -> stop/1 lifecycle" do
    test "completes a full lifecycle with a successful result" do
      handle = make_ref()

      team_result = %TeamResult{
        team: "backend",
        status: :success,
        result: "All tasks completed",
        input_tokens: 1000,
        output_tokens: 500,
        session_id: "sess-123"
      }

      MockProvider
      |> expect(:start, fn config ->
        assert config.provider == :cli
        {:ok, handle}
      end)
      |> expect(:run, fn h, prompt, opts ->
        assert h == handle
        assert prompt == "Build the API"
        assert opts[:team_name] == "backend"
        {:ok, team_result}
      end)
      |> expect(:stop, fn h ->
        assert h == handle
        :ok
      end)

      assert {:ok, ^handle} = MockProvider.start(%{provider: :cli, model: "sonnet"})

      assert {:ok, %TeamResult{team: "backend", status: :success}} =
               MockProvider.run(handle, "Build the API", team_name: "backend")

      assert :ok = MockProvider.stop(handle)
    end
  end

  describe "run/3 error handling" do
    test "returns {:error, reason} on failure" do
      handle = make_ref()

      MockProvider
      |> expect(:start, fn _config -> {:ok, handle} end)
      |> expect(:run, fn _h, _prompt, _opts ->
        {:error, {:exit_code, 1, "command not found"}}
      end)
      |> expect(:stop, fn _h -> :ok end)

      {:ok, h} = MockProvider.start(%{provider: :cli})

      assert {:error, {:exit_code, 1, _}} =
               MockProvider.run(h, "Build the API", team_name: "backend")

      assert :ok = MockProvider.stop(h)
    end
  end

  describe "start/1 error handling" do
    test "returns {:error, reason} when initialization fails" do
      MockProvider
      |> expect(:start, fn _config ->
        {:error, :command_not_found}
      end)

      assert {:error, :command_not_found} =
               MockProvider.start(%{provider: :cli, command: "nonexistent"})
    end
  end

  describe "stream/3" do
    test "returns an enumerable of tagged events" do
      handle = make_ref()

      team_result = %TeamResult{team: "frontend", status: :success}

      events = [
        {:session_started, "frontend", "sess-456"},
        {:token_update, "frontend", %{input_tokens: 100, output_tokens: 50}},
        {:activity, "frontend", %{type: :tool_use, tools: ["Read"]}},
        {:result, team_result}
      ]

      MockProvider
      |> expect(:start, fn _config -> {:ok, handle} end)
      |> expect(:stream, fn h, prompt, opts ->
        assert h == handle
        assert prompt == "Design the UI"
        assert opts[:team_name] == "frontend"
        {:ok, events}
      end)
      |> expect(:stop, fn _h -> :ok end)

      {:ok, h} = MockProvider.start(%{provider: :cli})
      {:ok, stream} = MockProvider.stream(h, "Design the UI", team_name: "frontend")

      collected = Enum.to_list(stream)
      assert length(collected) == 4
      assert {:session_started, "frontend", "sess-456"} = hd(collected)
      assert {:result, %TeamResult{team: "frontend"}} = List.last(collected)

      assert :ok = MockProvider.stop(h)
    end
  end

  describe "stop/1 idempotency" do
    test "can be called multiple times safely" do
      handle = make_ref()

      MockProvider
      |> expect(:start, fn _config -> {:ok, handle} end)
      |> expect(:stop, 2, fn _h -> :ok end)

      {:ok, h} = MockProvider.start(%{provider: :cli})
      assert :ok = MockProvider.stop(h)
      assert :ok = MockProvider.stop(h)
    end
  end

  describe "supports_stream?/1" do
    test "returns true for modules that implement stream/3" do
      defmodule StreamProvider do
        @behaviour Cortex.Provider

        @impl true
        def start(_config), do: {:ok, :handle}
        @impl true
        def run(_h, _prompt, _opts), do: {:ok, %TeamResult{team: "t", status: :success}}
        @impl true
        def stop(_h), do: :ok
        @impl true
        def stream(_h, _prompt, _opts), do: {:ok, []}
      end

      assert Cortex.Provider.supports_stream?(StreamProvider)
    end

    test "returns false for modules without stream/3" do
      refute Cortex.Provider.supports_stream?(Kernel)
    end
  end

  describe "supports_resume?/1" do
    test "returns true for modules that implement resume/2" do
      defmodule ResumeProvider do
        @behaviour Cortex.Provider

        @impl true
        def start(_config), do: {:ok, :handle}
        @impl true
        def run(_h, _prompt, _opts), do: {:ok, %TeamResult{team: "t", status: :success}}
        @impl true
        def stop(_h), do: :ok
        @impl true
        def resume(_h, _opts), do: {:ok, %TeamResult{team: "t", status: :success}}
      end

      assert Cortex.Provider.supports_resume?(ResumeProvider)
    end

    test "returns false for modules without resume/2" do
      refute Cortex.Provider.supports_resume?(Kernel)
    end
  end

  describe "resume/2" do
    test "resumes a session and returns a TeamResult" do
      handle = make_ref()

      team_result = %TeamResult{
        team: "backend",
        status: :success,
        result: "Resumed successfully",
        session_id: "sess-789"
      }

      MockProvider
      |> expect(:start, fn _config -> {:ok, handle} end)
      |> expect(:resume, fn h, opts ->
        assert h == handle
        assert opts[:session_id] == "sess-789"
        assert opts[:team_name] == "backend"
        {:ok, team_result}
      end)
      |> expect(:stop, fn _h -> :ok end)

      {:ok, h} = MockProvider.start(%{provider: :cli})

      assert {:ok, %TeamResult{status: :success, session_id: "sess-789"}} =
               MockProvider.resume(h, session_id: "sess-789", team_name: "backend")

      assert :ok = MockProvider.stop(h)
    end
  end
end
