defmodule Agora.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :agora,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix]],
      docs: [main: "Agora", extras: ["docs/Design-v0.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Agora.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.0", only: :test},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
