defmodule KogenBare.MixProject do
  use Mix.Project

  def project do
    [app: :kogen_bare, version: "0.0.0-dev", elixir: ">= 1.20.0", deps: []]
  end

  def application, do: [extra_applications: [:inets, :ssl, :public_key]]
end
