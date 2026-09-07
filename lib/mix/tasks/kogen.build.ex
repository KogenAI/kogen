defmodule Mix.Tasks.Kogen.Build do
  use Mix.Task
  use Boundary, deps: [Kogen.Build, Mix]

  @shortdoc "Runs the Kogen Build loop for an Approved Intent"
  @moduledoc """
  `mix kogen.build <slug>` drives the Approved Intent at
  `.kogen/intents/approved/<slug>` through Develop, Check, declared targets,
  Review, bounded Rework, and one ordinary Git Commit.
  """

  @impl Mix.Task
  def run([slug]) when is_binary(slug) and slug != "" do
    case Kogen.Build.run(slug) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, reason)
        System.halt(1)
    end
  end

  def run(_other) do
    IO.puts(:stderr, "usage: mix kogen.build <slug>")
    System.halt(1)
  end
end
