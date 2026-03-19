defmodule Cortex.Provider.Resolver do
  @moduledoc """
  Resolves a Provider implementation module from orchestration config.

  Given a `Team` struct and project `Defaults`, determines which Provider
  module should be used to communicate with the LLM. Resolution order:

  1. Team-level `:provider` field (if present on the struct)
  2. Defaults-level `:provider` field
  3. Falls back to `:cli` (i.e. `Cortex.Provider.CLI`)

  ## Examples

      iex> team = %Team{name: "arch", lead: %Lead{role: "Architect"}, tasks: []}
      iex> defaults = %Defaults{provider: :cli}
      iex> Resolver.resolve(team, defaults)
      {:ok, Cortex.Provider.CLI}

      iex> defaults = %Defaults{provider: :external}
      iex> Resolver.resolve(team, defaults)
      {:ok, Cortex.Provider.External}

  """

  alias Cortex.Orchestration.Config.Defaults
  alias Cortex.Orchestration.Config.Team

  @provider_modules %{
    cli: Cortex.Provider.CLI,
    http: Cortex.Provider.HTTP,
    external: Cortex.Provider.External
  }

  @doc """
  Resolves the Provider module for a given team and defaults.

  Returns `{:ok, module}` on success, or `{:error, {:unknown_provider, atom}}`
  if the provider name doesn't map to a known module.

  ## Parameters

    - `team` — a `%Team{}` struct (may have an optional `:provider` field)
    - `defaults` — a `%Defaults{}` struct with a `:provider` field

  """
  @spec resolve(Team.t(), Defaults.t()) :: {:ok, module()} | {:error, {:unknown_provider, atom()}}
  def resolve(%Team{} = team, %Defaults{} = defaults) do
    provider_name = team_provider(team) || defaults.provider || :cli

    case Map.fetch(@provider_modules, provider_name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_provider, provider_name}}
    end
  end

  @doc """
  Resolves the Provider module, raising on failure.

  Same as `resolve/2` but returns the module directly or raises
  an `ArgumentError` for unknown providers.

  ## Parameters

    - `team` — a `%Team{}` struct
    - `defaults` — a `%Defaults{}` struct

  """
  @spec resolve!(Team.t(), Defaults.t()) :: module()
  def resolve!(%Team{} = team, %Defaults{} = defaults) do
    case resolve(team, defaults) do
      {:ok, module} ->
        module

      {:error, {:unknown_provider, name}} ->
        raise ArgumentError, "unknown provider: #{inspect(name)}"
    end
  end

  # Returns the team's :provider override, or nil to fall back to defaults.
  @spec team_provider(Team.t()) :: atom() | nil
  defp team_provider(%Team{provider: provider}), do: provider
end
