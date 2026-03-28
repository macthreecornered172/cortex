defmodule Cortex.Output.Store do
  @moduledoc """
  Behaviour for storing and retrieving team output content.

  Agent teams produce deliverables (workout plans, meal plans, code, etc.)
  that can be large text documents. This module defines the contract for
  persisting those outputs outside the database, keeping the DB lean
  (it stores only an `output_key` pointer).

  ## Backends

    - `Cortex.Output.Store.Local` — writes to the local filesystem
      (`.cortex/outputs/` under the workspace). Good for dev/test.

  ## Configuration

      config :cortex, Cortex.Output.Store,
        backend: Cortex.Output.Store.Local

  """

  @type key :: String.t()
  @type opts :: keyword()

  @doc "Stores content at the given key."
  @callback put(key(), binary(), opts()) :: :ok | {:error, term()}

  @doc "Retrieves content by key."
  @callback get(key()) :: {:ok, binary()} | {:error, :not_found | term()}

  @doc "Deletes content at the given key."
  @callback delete(key()) :: :ok | {:error, term()}

  @doc "Lists all keys under the given prefix."
  @callback list_keys(String.t()) :: {:ok, [key()]} | {:error, term()}

  # -- Convenience delegators --------------------------------------------------

  @doc "Stores content using the configured backend."
  @spec put(key(), binary(), opts()) :: :ok | {:error, term()}
  def put(key, content, opts \\ []) do
    backend().put(key, content, opts)
  end

  @doc "Retrieves content using the configured backend."
  @spec get(key()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get(key) do
    backend().get(key)
  end

  @doc "Deletes content using the configured backend."
  @spec delete(key()) :: :ok | {:error, term()}
  def delete(key) do
    backend().delete(key)
  end

  @doc "Lists all keys under the given prefix using the configured backend."
  @spec list_keys(String.t()) :: {:ok, [key()]} | {:error, term()}
  def list_keys(prefix) do
    backend().list_keys(prefix)
  end

  @doc "Builds a storage key for a team's output within a run."
  @spec build_key(String.t(), String.t()) :: key()
  def build_key(run_id, team_name) do
    "runs/#{run_id}/teams/#{team_name}/output"
  end

  @doc "Builds a storage key for a workspace file within a run."
  @spec build_workspace_key(String.t(), String.t()) :: key()
  def build_workspace_key(run_id, relative_path) do
    "runs/#{run_id}/workspace/#{relative_path}"
  end

  @spec backend() :: module()
  defp backend do
    Application.get_env(:cortex, __MODULE__, [])
    |> Keyword.get(:backend, Cortex.Output.Store.Local)
  end
end
