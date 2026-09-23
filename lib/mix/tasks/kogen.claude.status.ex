defmodule Mix.Tasks.Kogen.Claude.Status do
  @moduledoc false
  use Mix.Task
  use Boundary, deps: [Kogen.ClaudeCode.CLI, Mix]
  alias Kogen.ClaudeCode.CLI
  @shortdoc "Reports the managed Claude Code pin, installation and login metadata"
  @impl Mix.Task
  def run(args), do: CLI.run(:status, args)
end
