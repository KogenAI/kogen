defmodule Mix.Tasks.Kogen.Codex.Status do
  @moduledoc false
  use Mix.Task
  use Boundary, deps: [Kogen.Codex.CLI, Mix]
  alias Kogen.Codex.CLI
  @shortdoc "Reports managed Codex runtime and local login state"
  @impl Mix.Task
  def run(args), do: CLI.run(:status, args)
end
