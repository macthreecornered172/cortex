defmodule Cortex.Output.Store.Local do
  @moduledoc """
  Local filesystem backend for `Cortex.Output.Store`.

  Stores output content as plain files under a configurable base directory.
  Keys map directly to file paths (e.g., `runs/<run_id>/teams/<team>/output`).

  ## Configuration

      config :cortex, Cortex.Output.Store.Local,
        base_path: "/tmp/cortex/outputs"

  If no `base_path` is configured, defaults to `"priv/outputs"` relative
  to the application root.
  """

  @behaviour Cortex.Output.Store

  @impl true
  @spec put(String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def put(key, content, _opts \\ []) when is_binary(key) and is_binary(content) do
    path = key_to_path(key)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, content)
  end

  @impl true
  @spec get(String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get(key) when is_binary(key) do
    path = key_to_path(key)

    case File.read(path) do
      {:ok, _} = ok -> ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @impl true
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key) do
    path = key_to_path(key)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec key_to_path(String.t()) :: String.t()
  defp key_to_path(key) do
    Path.join(base_path(), key)
  end

  @spec base_path() :: String.t()
  defp base_path do
    Application.get_env(:cortex, __MODULE__, [])
    |> Keyword.get(:base_path, Path.join(File.cwd!(), "priv/outputs"))
  end
end
