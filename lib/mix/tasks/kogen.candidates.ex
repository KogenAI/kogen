defmodule Mix.Tasks.Kogen.Candidates do
  use Mix.Task
  use Boundary, deps: [Kogen.Build, Mix]

  alias Kogen.Build.Workspace

  @shortdoc "Lists this project's kept Build Candidates"
  @moduledoc """
  `mix kogen.candidates` lists the Candidate worktrees that Builds of this
  control checkout created and kept: build id, slug, title, status, start
  time, branch and path. Only Candidates with an owner record under this
  checkout's project id (`Kogen.Build.Workspace.project_dir/1`, keyed off the
  process working directory) are listed -- never another project's, and
  never a Kogen-foreign worktree. A `running` record whose Build no longer
  holds this checkout's build lock is shown as `stopped: interrupted`. A
  malformed or mismatched owner record is reported and skipped rather than
  raised.

  This task is the only place it reads the process working directory, once,
  to find the control checkout (a main worktree, never a linked one), the
  same convention `mix kogen.build` and `mix kogen.candidates.remove` use.
  """

  @usage "usage: mix kogen.candidates"

  @impl Mix.Task
  def run([]) do
    control = File.cwd!()

    case Workspace.list(control) do
      [] -> IO.puts("No Kogen Candidates for this project.")
      entries -> Enum.each(entries, &print/1)
    end
  end

  def run(_args), do: Mix.raise(@usage)

  defp print({:ok, record}) do
    IO.puts("""
    #{record["build_id"]}
      slug:    #{record["slug"]}
      title:   #{record["title"]}
      status:  #{record["status"]}#{commit(record)}
      started: #{record["started_at"]}
      branch:  #{record["branch"]}
      path:    #{record["worktree_path"]}\
    """)
  end

  defp print({:error, path, reason}), do: IO.puts("skipped #{path}: #{reason}")

  defp commit(%{"candidate_commit" => commit}) when is_binary(commit),
    do: " (Candidate commit #{commit})"

  defp commit(_record), do: ""
end
