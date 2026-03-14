defmodule Cortex.MixProject do
  use Mix.Project

  def project do
    [
      app: :cortex,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Cortex.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:uniq, "~> 0.6"},
      {:yaml_elixir, "~> 2.9"},
      {:jason, "~> 1.4"}
    ]
  end
end
