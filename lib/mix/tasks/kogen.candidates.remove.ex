defmodule Mix.Tasks.Kogen.Candidates.Remove do
  use Mix.Task
  use Boundary, deps: [Kogen.Build, Mix]

  alias Kogen.Build.Workspace

  @shortdoc "Removes one of this project's kept Build Candidates"
  @moduledoc """
  `mix kogen.candidates.remove <build-id> [--discard-accepted]` deletes one of
  this control checkout's Candidates: its worktree (forced, since a stopped
  Candidate's uncommitted edits are expected), its branch (`-D`), its harness
  home and its owner record.

  It refuses a running Candidate (its Build holds the build lock), an id that
  is not this checkout's, and a path that does not match its owner record or
  is not registered in this repository's `git worktree list`. A Candidate
  holding a commit that is not reachable from its admitted branch is refused
  unless `--discard-accepted` is passed; a Candidate whose held commit is
  already reachable (for example after the Shaper fast-forwards the admitted
  branch onto it) is removed without the flag. Every refusal and every
  removal prints what it named; nothing is removed on refusal.

  This task is the only place it reads the process working directory, once,
  to find the control checkout, the same convention `mix kogen.build` and
  `mix kogen.candidates` use.
  """

  @usage "usage: mix kogen.candidates.remove <build-id> [--discard-accepted]"

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: [discard_accepted: :boolean]) do
      {options, [build_id], []} when build_id != "" ->
        remove(build_id, Keyword.get(options, :discard_accepted, false))

      _usage ->
        Mix.raise(@usage)
    end
  end

  defp remove(build_id, discard?) do
    case Workspace.remove(File.cwd!(), build_id, discard_accepted: discard?) do
      {:ok, removed} -> Enum.each(removed, &IO.puts/1)
      {:error, reason} -> Mix.raise(reason)
    end
  end
end
