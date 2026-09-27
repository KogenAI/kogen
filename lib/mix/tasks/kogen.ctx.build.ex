defmodule Mix.Tasks.Kogen.Ctx.Build do
  @moduledoc "Builds the native kogen-ctx binary."
  use Mix.Task
  use Boundary, deps: [Kogen.Ctx, Mix]
  @shortdoc "Build the native kogen-ctx binary"
  def run(args) do
    {offline, rest} = Enum.split_with(args, &(&1 == "--offline"))
    if rest != [], do: Mix.raise("usage: mix kogen.ctx.build [--offline]")
    root = File.cwd!()

    with :ok <- Kogen.Ctx.fetch(root, offline: offline != []),
         {:ok, path} <- Kogen.Ctx.build(root) do
      Mix.shell().info(Path.expand(path))
    else
      {:error, reason} -> Mix.raise(reason)
    end
  end
end
