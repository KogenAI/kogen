# credo:disable-for-this-file Credo.Check.Refactor.Nesting
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
    published = published_line(record)
    report = report_line(record)
    lines = if published == "", do: "  #{report}", else: "  #{published}\n  #{report}"

    IO.puts(
      "#{record["build_id"]}\n  slug:    #{record["slug"]}\n  title:   #{record["title"]}\n  status:  #{record["status"]}#{commit(record)}\n  started: #{record["started_at"]}\n  branch:  #{record["branch"]}\n  path:    #{record["worktree_path"]}\n#{lines}\n"
    )
  end

  defp print({:error, path, reason}), do: IO.puts("skipped #{path}: #{reason}")

  defp commit(%{"candidate_commit" => commit}) when is_binary(commit),
    do: " (Candidate commit #{commit})"

  defp commit(_record), do: ""

  defp report_line(record) do
    control = record["control_root"]

    path =
      Path.join([
        control,
        ".kogen/runtime/scenario-tracking",
        record["build_id"],
        "failure-report.json"
      ])

    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, report} ->
            next =
              case report["next_command"] do
                command when is_binary(command) and command != "" ->
                  "#{report["next_action"]} (#{command})"

                _ ->
                  report["next_action"]
              end

            "class:   #{report["class"]}\n      next:    #{next}\n      report:  #{path}"

          _ ->
            "report:  #{path}"
        end

      _ ->
        "report:   none"
    end
  end

  defp published_line(record) do
    if record["status"] in ["stopped: interrupted", "stopped: publication-interrupted"] do
      case Workspace.published_tip(record["control_root"], record) do
        tip when is_binary(tip) ->
          "published: #{tip} is on #{record["admitted_branch"]}; remove it with mix kogen.candidates.remove #{record["build_id"]}"

        _ ->
          ""
      end
    else
      ""
    end
  end
end
