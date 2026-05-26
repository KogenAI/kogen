defmodule CodegenTestHarness.MixProject do
  use Mix.Project

  def project do
    [
      app: :codegen_test_harness,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    []
  end

  defp deps do
    []
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
