defmodule Mix.Tasks.Kogen.Shape.Runner do
  @moduledoc false
  use Mix.Task

  use Boundary, deps: [Kogen.Shaping, Mix]

  alias Kogen.Shaping.Runner

  @impl Mix.Task
  def run([id]) do
    Process.group_leader(self(), Process.whereis(:standard_error))
    Runner.run(File.cwd!(), id)
    System.halt(0)
  end

  def run(_args) do
    IO.puts(:stderr, "usage: mix kogen.shape.runner ID")
    System.halt(2)
  end
end
