defmodule Cortex.Provider do
  @moduledoc """
  Behaviour for LLM provider communication.

  A Provider abstracts how Cortex communicates with an LLM — whether via
  a local CLI process, an HTTP API, or a remote sidecar agent. The
  orchestration layer dispatches work through this interface without
  knowing which provider implementation is in use.

  ## Lifecycle

      {:ok, handle} = MyProvider.start(config)
      {:ok, result} = MyProvider.run(handle, prompt, opts)
      :ok = MyProvider.stop(handle)

  ## Callbacks

  Required callbacks:

    - `start/1` — initialize provider resources
    - `run/3` — synchronous prompt execution, returns a `TeamResult`
    - `stop/1` — release provider resources (idempotent)

  Optional callbacks:

    - `stream/3` — streaming execution returning an enumerable of events
    - `resume/2` — resume a previous session

  ## Example Implementation

      defmodule Cortex.Provider.CLI do
        @behaviour Cortex.Provider

        @impl true
        def start(config), do: {:ok, %{command: config[:command] || "claude"}}

        @impl true
        def run(handle, prompt, opts) do
          # ... spawn process, parse output, build TeamResult
          {:ok, %Cortex.Orchestration.TeamResult{team: opts[:team_name], status: :success}}
        end

        @impl true
        def stop(_handle), do: :ok
      end
  """

  alias Cortex.Orchestration.TeamResult

  @typedoc """
  Provider-specific configuration.

  A keyword list with provider-specific options. Additional keys are
  implementation-specific.
  """
  @type config() :: keyword()

  @typedoc """
  Opaque handle returned by `start/1`.

  Each implementation defines its own handle shape. Callers must not
  inspect or pattern-match on handle internals — only pass them back
  to the originating implementation's callbacks.
  """
  @type handle() :: term()

  @typedoc """
  Streaming event emitted by `stream/3`.

  Events are tagged tuples so consumers can pattern-match without
  knowing the provider implementation.
  """
  @type event() ::
          {:token_update, team_name :: String.t(), tokens :: map()}
          | {:activity, team_name :: String.t(), activity :: map()}
          | {:session_started, team_name :: String.t(), session_id :: String.t()}
          | {:result, TeamResult.t()}
          | {:error, term()}

  @typedoc """
  Per-run options passed to `run/3` and `stream/3`.
  """
  @type run_opts() :: keyword()

  @doc """
  Initialize provider resources.

  For CLI: resolve command path, validate model.
  For HTTP: establish connection pool.
  For External: verify Gateway connectivity.

  Returns an opaque handle for use with other callbacks.
  """
  @callback start(config :: config()) :: {:ok, handle()} | {:error, term()}

  @doc """
  Synchronous prompt execution.

  Sends the prompt to the LLM, blocks until completion, and returns
  a `TeamResult`. This is the primary execution path used by
  `Runner.Executor.run_team/6`.
  """
  @callback run(handle :: handle(), prompt :: String.t(), opts :: run_opts()) ::
              {:ok, TeamResult.t()} | {:error, term()}

  @doc """
  Release provider resources. Idempotent.

  Calling `stop/1` on an already-stopped handle returns `:ok`
  without side effects.
  """
  @callback stop(handle :: handle()) :: :ok

  @doc """
  Streaming prompt execution.

  Returns a lazy enumerable of `event()` tuples. Consumers can
  `Enum.each/2` for side effects (broadcasting token updates,
  activity notifications) or collect the final `:result` event.

  Optional — implementations that don't support streaming can omit
  this callback. Callers should check `supports_stream?/1` before
  calling.
  """
  @callback stream(handle :: handle(), prompt :: String.t(), opts :: run_opts()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Resume a previous session.

  Optional — only providers that support session persistence (e.g.,
  CLI with session IDs) implement this. Callers should check
  `supports_resume?/1` before calling.
  """
  @callback resume(handle :: handle(), opts :: run_opts()) ::
              {:ok, TeamResult.t()} | {:error, term()}

  @optional_callbacks [stream: 3, resume: 2]

  @doc """
  Check whether a provider module implements the optional `stream/3` callback.
  """
  @spec supports_stream?(module()) :: boolean()
  def supports_stream?(module) when is_atom(module) do
    function_exported?(module, :stream, 3)
  end

  @doc """
  Check whether a provider module implements the optional `resume/2` callback.
  """
  @spec supports_resume?(module()) :: boolean()
  def supports_resume?(module) when is_atom(module) do
    function_exported?(module, :resume, 2)
  end
end
