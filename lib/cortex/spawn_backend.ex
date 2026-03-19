defmodule Cortex.SpawnBackend do
  @moduledoc """
  Behaviour for compute process management.

  A SpawnBackend abstracts where agent processes run — whether as a
  local Erlang port, a Docker container, or a Kubernetes Pod. Provider
  implementations use a SpawnBackend to manage the underlying compute
  lifecycle.

  ## Lifecycle

      {:ok, handle} = MyBackend.spawn(config)
      {:ok, stream} = MyBackend.stream(handle)
      :running = MyBackend.status(handle)
      :ok = MyBackend.stop(handle)

  ## Callbacks

  All four callbacks are required:

    - `spawn/1` — start the compute process
    - `stream/1` — get raw output stream from the process
    - `stop/1` — terminate the process (idempotent)
    - `status/1` — poll current process status

  ## Separation from Provider

  SpawnBackend handles compute lifecycle (start, stop, stream bytes).
  Provider handles LLM protocol (parse, interpret, structure results).
  A Provider implementation may internally use a SpawnBackend, but the
  behaviours are independent — `Provider.External` uses Gateway directly
  with no SpawnBackend.

  ## Example Implementation

      defmodule Cortex.SpawnBackend.Local do
        @behaviour Cortex.SpawnBackend

        @impl true
        def spawn(config) do
          port = Port.open({:spawn_executable, config[:command]}, [:binary, :exit_status])
          {:ok, %{port: port}}
        end

        @impl true
        def stream(handle) do
          stream = Stream.resource(fn -> handle end, &receive_chunk/1, fn _ -> :ok end)
          {:ok, stream}
        end

        @impl true
        def stop(%{port: port}) do
          Port.close(port)
          :ok
        end

        @impl true
        def status(%{port: port}) do
          if Port.info(port), do: :running, else: :done
        end
      end
  """

  @typedoc """
  Backend-specific configuration.

  A keyword list with backend-specific options such as `:command`,
  `:cwd`, `:timeout_ms`, and `:env`. Additional keys are
  implementation-specific.
  """
  @type config() :: keyword()

  @typedoc """
  Opaque handle returned by `spawn/1`.

  Each implementation defines its own handle shape. For Local this is
  a port reference wrapper; for Docker it would be a container ID; for
  K8s it would be a Pod name + namespace. Callers must not inspect
  handle internals.
  """
  @type handle() :: term()

  @typedoc """
  Process status.

    - `:running` — the process is alive and accepting input
    - `:done` — the process exited successfully
    - `:failed` — the process exited with an error
  """
  @type status() :: :running | :done | :failed

  @doc """
  Start the compute process.

  Opens an Erlang port, starts a Docker container, creates a K8s Pod,
  etc. Returns an opaque handle for use with other callbacks.
  """
  @callback spawn(config :: config()) :: {:ok, handle()} | {:error, term()}

  @doc """
  Get the raw output stream from the compute process.

  Returns a lazy enumerable of binary chunks. The Provider
  implementation is responsible for parsing these into structured
  events. Use `Stream.resource/3` to wrap polling-based backends.
  """
  @callback stream(handle :: handle()) :: {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Terminate the compute process. Idempotent.

  For Local: `Port.close/1`. For Docker: `docker stop`. For K8s:
  delete Pod. Calling `stop/1` on an already-stopped handle returns
  `:ok` without side effects.
  """
  @callback stop(handle :: handle()) :: :ok

  @doc """
  Poll current process status. Must be non-blocking.

  Returns `:running` if the process is alive, `:done` if it exited
  successfully, or `:failed` if it exited with an error. Never raises.
  """
  @callback status(handle :: handle()) :: status()
end
