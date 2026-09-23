defmodule Mix.Tasks.Kogen.Claude.Login do
  @moduledoc """
  Opens the managed interactive Claude Code in the selected Kogen login scope
  so you complete Claude Code's own first-run flow, including its login
  (Claude subscription or Anthropic Console API billing), then exit.

      mix kogen.claude.login              # Kogen's shared scope
      mix kogen.claude.login --project    # this project's private scope
      mix kogen.claude.login --use-default

  `--use-default` switches this project back to the shared scope and keeps
  retained project logins. Everything after `--` is forwarded unchanged to the
  managed `claude`. Kogen's scopes are separate from personal Claude Code;
  Kogen never reads, copies or prints credential values.
  """
  use Mix.Task
  use Boundary, deps: [Kogen.ClaudeCode.CLI, Mix]
  alias Kogen.ClaudeCode.CLI
  @shortdoc "Logs the selected Kogen Claude Code scope in"
  @impl Mix.Task
  def run(args), do: CLI.run(:login, args)
end
