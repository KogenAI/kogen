defmodule TinyTasks.MixProject do
  use Mix.Project

  def project do
    [
      app: :tiny_tasks,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [],
      test_paths: ["test"]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
