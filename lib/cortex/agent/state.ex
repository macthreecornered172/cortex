defmodule Cortex.Agent.State do
  @moduledoc """
  Agent runtime state struct with update functions.

  A `State` holds the mutable runtime data of a single agent GenServer process.
  It is created from a validated `Config` and tracks the agent's lifecycle:
  status, metadata, and timestamps.

  ## Fields

    - `id` — a UUID string, generated at creation via `Uniq.UUID.uuid4()`
    - `config` — the immutable `Cortex.Agent.Config` struct
    - `status` — one of `:idle`, `:running`, `:done`, `:failed`
    - `metadata` — mutable map for coordination data
    - `started_at` — UTC timestamp of when the state was created
    - `updated_at` — UTC timestamp of the last mutation

  ## Status Lifecycle

  Valid statuses: `:idle`, `:running`, `:done`, `:failed`.
  No transition validation is enforced (e.g., `:done` -> `:running` is allowed).
  State machine constraints may be added in a future phase.
  """

  alias Cortex.Agent.Config

  @valid_statuses [:idle, :running, :done, :failed]

  @enforce_keys [:id, :config, :status, :started_at, :updated_at]
  defstruct [
    :id,
    :config,
    :status,
    :started_at,
    :updated_at,
    metadata: %{}
  ]

  @type status :: :idle | :running | :done | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          config: Config.t(),
          status: status(),
          metadata: map(),
          started_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Creates a new `State` from a validated `Config`.

  Generates a UUID for the agent ID, sets status to `:idle`, initializes
  metadata from the config, and stamps both `started_at` and `updated_at`
  to the current UTC time.

  ## Parameters

    - `config` — a validated `%Cortex.Agent.Config{}` struct

  ## Examples

      iex> config = Cortex.Agent.Config.new!(%{name: "worker", role: "builder"})
      iex> state = Cortex.Agent.State.new(config)
      iex> state.status
      :idle

  """
  @spec new(Config.t()) :: t()
  def new(%Config{} = config) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: Uniq.UUID.uuid4(),
      config: config,
      status: :idle,
      metadata: config.metadata,
      started_at: now,
      updated_at: now
    }
  end

  @doc """
  Updates the status of an agent state.

  Returns `{:ok, updated_state}` with a new `updated_at` timestamp if the
  status is valid, or `{:error, :invalid_status}` if the status atom is not
  one of `:idle`, `:running`, `:done`, `:failed`.

  ## Parameters

    - `state` — the current `%State{}` struct
    - `new_status` — the target status atom

  ## Examples

      iex> {:ok, state} = State.update_status(state, :running)
      iex> state.status
      :running

  """
  @spec update_status(t(), status()) :: {:ok, t()} | {:error, :invalid_status}
  def update_status(%__MODULE__{} = state, new_status) when new_status in @valid_statuses do
    {:ok, %{state | status: new_status, updated_at: DateTime.utc_now()}}
  end

  def update_status(%__MODULE__{}, _invalid_status) do
    {:error, :invalid_status}
  end

  @doc """
  Updates a single key in the agent's metadata map.

  Always succeeds. Returns the updated state with a new `updated_at` timestamp.

  ## Parameters

    - `state` — the current `%State{}` struct
    - `key` — the metadata key to set
    - `value` — the value to associate with the key

  ## Examples

      iex> state = State.update_metadata(state, :work, %{task: "research"})
      iex> state.metadata[:work]
      %{task: "research"}

  """
  @spec update_metadata(t(), term(), term()) :: t()
  def update_metadata(%__MODULE__{} = state, key, value) do
    new_metadata = Map.put(state.metadata, key, value)
    %{state | metadata: new_metadata, updated_at: DateTime.utc_now()}
  end

  @doc """
  Returns the list of valid status atoms.
  """
  @spec valid_statuses() :: [status()]
  def valid_statuses, do: @valid_statuses
end
