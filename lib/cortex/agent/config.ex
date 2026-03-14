defmodule Cortex.Agent.Config do
  @moduledoc """
  Agent configuration struct with validation.

  A `Config` defines the immutable configuration for a single agent process.
  Once an agent is started, its config cannot be changed. To run an agent
  with different config, stop it and start a new one.

  ## Required Fields

    - `name` — a non-empty string identifying the agent
    - `role` — a non-empty string describing the agent's role

  ## Optional Fields (with defaults)

    - `model` — LLM model identifier (default: `"sonnet"`)
    - `max_turns` — maximum conversation turns (default: `200`)
    - `timeout_minutes` — execution timeout in minutes (default: `30`)
    - `metadata` — arbitrary metadata map (default: `%{}`)

  ## Examples

      iex> Cortex.Agent.Config.new(%{name: "researcher", role: "research lead"})
      {:ok, %Cortex.Agent.Config{name: "researcher", role: "research lead", model: "sonnet", max_turns: 200, timeout_minutes: 30, metadata: %{}}}

      iex> Cortex.Agent.Config.new(%{})
      {:error, ["name is required", "role is required"]}

  """

  @enforce_keys [:name, :role]
  defstruct [
    :name,
    :role,
    model: "sonnet",
    max_turns: 200,
    timeout_minutes: 30,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          role: String.t(),
          model: String.t(),
          max_turns: pos_integer(),
          timeout_minutes: pos_integer(),
          metadata: map()
        }

  @doc """
  Validates and constructs a `Config` struct from a map or keyword list.

  Returns `{:ok, config}` on success or `{:error, reasons}` where `reasons`
  is a list of validation error strings.

  ## Parameters

    - `attrs` — a map or keyword list of config attributes

  ## Examples

      iex> Config.new(%{name: "worker", role: "builder"})
      {:ok, %Config{name: "worker", role: "builder"}}

      iex> Config.new(%{name: "", role: "builder"})
      {:error, ["name cannot be empty"]}

  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    attrs = normalize_keys(attrs)

    case validate(attrs) do
      [] ->
        config = %__MODULE__{
          name: Map.fetch!(attrs, :name),
          role: Map.fetch!(attrs, :role),
          model: Map.get(attrs, :model, "sonnet"),
          max_turns: Map.get(attrs, :max_turns, 200),
          timeout_minutes: Map.get(attrs, :timeout_minutes, 30),
          metadata: Map.get(attrs, :metadata, %{})
        }

        {:ok, config}

      errors ->
        {:error, errors}
    end
  end

  @doc """
  Bang variant of `new/1`. Returns the `Config` struct on success or raises
  `ArgumentError` on validation failure.

  ## Examples

      iex> Config.new!(%{name: "worker", role: "builder"})
      %Config{name: "worker", role: "builder"}

  """
  @spec new!(map() | keyword()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, config} ->
        config

      {:error, reasons} ->
        raise ArgumentError,
              "invalid agent config: #{Enum.join(reasons, "; ")}"
    end
  end

  # --- Private Helpers ---

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} when is_atom(key) -> {key, value}
    end)
  rescue
    ArgumentError -> attrs
  end

  defp validate(attrs) do
    []
    |> validate_name(attrs)
    |> validate_role(attrs)
    |> validate_model(attrs)
    |> validate_max_turns(attrs)
    |> validate_timeout_minutes(attrs)
    |> validate_metadata(attrs)
    |> Enum.reverse()
  end

  defp validate_name(errors, attrs) do
    case Map.get(attrs, :name) do
      nil -> ["name is required" | errors]
      val when is_binary(val) -> validate_non_empty(errors, val, "name")
      _ -> ["name must be a string" | errors]
    end
  end

  defp validate_role(errors, attrs) do
    case Map.get(attrs, :role) do
      nil -> ["role is required" | errors]
      val when is_binary(val) -> validate_non_empty(errors, val, "role")
      _ -> ["role must be a string" | errors]
    end
  end

  defp validate_non_empty(errors, val, field_name) do
    if String.trim(val) == "" do
      ["#{field_name} cannot be empty" | errors]
    else
      errors
    end
  end

  defp validate_model(errors, attrs) do
    case Map.get(attrs, :model) do
      nil -> errors
      val when is_binary(val) -> errors
      _ -> ["model must be a string" | errors]
    end
  end

  defp validate_max_turns(errors, attrs) do
    case Map.get(attrs, :max_turns) do
      nil -> errors
      val when is_integer(val) and val > 0 -> errors
      _ -> ["max_turns must be a positive integer" | errors]
    end
  end

  defp validate_timeout_minutes(errors, attrs) do
    case Map.get(attrs, :timeout_minutes) do
      nil -> errors
      val when is_integer(val) and val > 0 -> errors
      _ -> ["timeout_minutes must be a positive integer" | errors]
    end
  end

  defp validate_metadata(errors, attrs) do
    case Map.get(attrs, :metadata) do
      nil -> errors
      val when is_map(val) -> errors
      _ -> ["metadata must be a map" | errors]
    end
  end
end
