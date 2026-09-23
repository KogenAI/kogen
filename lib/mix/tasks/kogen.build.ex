defmodule Mix.Tasks.Kogen.Build do
  use Mix.Task
  use Boundary, deps: [Kogen.Build, Mix]

  @shortdoc "Runs the Kogen Build loop for an Approved Intent"
  @moduledoc """
  `mix kogen.build [--route <name>] <slug>` drives the Approved Intent at
  `.kogen/intents/approved/<slug>` through Develop, Check, declared targets,
  Review, bounded Rework, and one ordinary Git Commit. The whole Build runs on
  the named route from `.kogen/config.yaml`, or on its `default_route` without
  `--route`.
  """

  @usage "usage: mix kogen.build [--route <name>] <slug>"

  @impl Mix.Task
  def run(args) do
    case parse(args) do
      {:ok, route, slug} -> build(slug, route)
      :usage -> fail(@usage)
    end
  end

  defp parse(args) do
    case OptionParser.parse(args, strict: [route: :string]) do
      {[], [slug], []} when slug != "" -> {:ok, nil, slug}
      {[route: route], [slug], []} when route != "" and slug != "" -> {:ok, route, slug}
      _usage -> :usage
    end
  end

  defp build(slug, route) do
    case Kogen.Build.run(slug, route) do
      :ok -> :ok
      {:error, reason} -> fail(reason)
    end
  end

  defp fail(reason) do
    IO.puts(:stderr, reason)
    System.halt(1)
  end
end
