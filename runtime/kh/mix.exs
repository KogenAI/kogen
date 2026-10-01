defmodule KhRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :kh_runtime,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [extra_applications: [:crypto, :inets, :ssl, :logger]]
  end
end
