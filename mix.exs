defmodule Kogen.MixProject do
  use Mix.Project

  def project do
    [
      app: :kogen,
      # Mix requires a version; this fixed placeholder is not a product release.
      version: "0.0.0+unversioned",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [check: [apps: [{:mix, :runtime}]]]],
      test_ignore_filters: [~r"/support/"],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:boundary, "~> 0.10", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
