defmodule Mix.Tasks.Kogen.Codex.Install do
  @moduledoc false
  use Mix.Task
  use Boundary, deps: [Kogen.Codex.CLI, Mix]
  alias Kogen.Codex.CLI
  @shortdoc "Installs the selected managed native Codex release"
  @impl Mix.Task
  def run(args), do: CLI.run(:install, args)
end
