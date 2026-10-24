defmodule Kogen.MixProject do
  use Mix.Project

  def project do
    [
      app: :kogen,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Helpers load explicitly; acceptance fixture projects run in their own repositories.
      test_load_filters: [
        &(String.ends_with?(&1, "_test.exs") and
            not String.starts_with?(&1, "test/acceptance/fixtures/"))
      ],
      test_ignore_filters: [
        &String.starts_with?(&1, ["test/support/", "test/acceptance/fixtures/"])
      ],
      releases: [kogen: [include_executables_for: [:unix], steps: [:assemble]]]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :public_key],
      mod: {Kogen.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
