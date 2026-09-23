defmodule Mix.Tasks.Kogen.Claude.Install do
  @moduledoc """
  Installs the exact Claude Code release pinned by this Kogen checkout into
  Kogen's managed root (`~/Library/Application Support/Kogen/claude`).

  The native binary is downloaded from the official npm registry, checked
  against the pinned sha512 integrity, staged privately and published
  atomically. An intact installation is reused; a failure leaves any working
  runtime and every login untouched. Personal Claude Code is never used.
  """
  use Mix.Task
  use Boundary, deps: [Kogen.ClaudeCode.CLI, Mix]
  alias Kogen.ClaudeCode.CLI
  @shortdoc "Installs the pinned managed Claude Code runtime"
  @impl Mix.Task
  def run(args), do: CLI.run(:install, args)
end
