defmodule Mix.Tasks.Codegen.Pitches.Scope do
  @shortdoc "Reports scope: collisions/disjoint/unrouted across a pitch batch"

  @moduledoc """
  `mix codegen.pitches.scope [--dir=ready] [--cwd=.]`

  Deterministic, offline reader over the `scope:` frontmatter field (see
  `codegen/pitches/ready/a-pitch-declares-the-files-it-will-touch.md`).
  Answers "which pitches in this batch touch the same files?" without an
  LLM call — the operator question this task exists to make answerable.

  Delegates entirely to `CodegenTestHarness.LoopQueue.scope_report/1`.
  This task is I/O + formatting only; it adds no gate, no retire
  behavior, and no partitioning — it is a report, not a scheduler.

  ## Flags

  - `--dir` — optional, one of `ready` | `draft` | `shipped` (default
    `ready`) — resolved relative to `<cwd>/codegen/pitches/`
  - `--cwd` — optional, project root whose `codegen/pitches/<dir>/` is
    scanned (default `File.cwd!/0`, the directory `mix` was invoked
    from)

  ## Output

  Three sections:

    - `COLLISIONS` — pairs of pitches whose `scope:` lists share at
      least one path, and the shared paths
    - `DISJOINT` — scoped pitches sharing no file with any other scoped
      pitch in the batch — safe to route to different machines/lanes
    - `UNROUTED` — pitches with no `scope:` field at all — a human must
      place these; absence is reported, never guessed at

  ## Exit codes

  - `0` — report printed (including the all-empty / all-unrouted case)
  - non-zero — a pitch's `scope:` value is present but not a parseable
    `[...]` flow-list (`LoopQueue.parse_scope/2` raises loud rather than
    silently returning an empty/wrong partition), or `--dir` names an
    unrecognized value
  """

  use Mix.Task

  alias CodegenTestHarness.LoopQueue

  @valid_dirs ~w(ready draft shipped)

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, _positional, invalid} =
      OptionParser.parse(argv, strict: [dir: :string, cwd: :string])

    if invalid != [] do
      Mix.shell().error("codegen.pitches.scope: invalid flags: #{inspect(invalid)}")
      exit({:shutdown, 2})
    end

    dir_name = Keyword.get(opts, :dir, "ready")
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    unless dir_name in @valid_dirs do
      Mix.shell().error(
        "codegen.pitches.scope: --dir must be one of #{inspect(@valid_dirs)}, got #{inspect(dir_name)}"
      )

      exit({:shutdown, 2})
    end

    pitches_dir = Path.join([cwd, "codegen", "pitches", dir_name]) |> Path.expand()

    unless File.dir?(pitches_dir) do
      Mix.shell().info("no pitches in #{pitches_dir}")
      exit(:normal)
    end

    {disjoint, collisions, unrouted} = LoopQueue.scope_report(pitches_dir)

    print_collisions(collisions)
    print_disjoint(disjoint)
    print_unrouted(unrouted)
  end

  defp print_collisions([]) do
    IO.puts(IO.ANSI.bright() <> "COLLISIONS (0 pairs share an edit surface)" <> IO.ANSI.reset())
    IO.puts("")
  end

  defp print_collisions(collisions) do
    IO.puts(
      IO.ANSI.bright() <>
        "COLLISIONS (#{length(collisions)} pair#{plural(length(collisions))} share an edit surface)" <>
        IO.ANSI.reset()
    )

    Enum.each(collisions, fn {slug_a, slug_b, shared_paths} ->
      IO.puts("  #{slug_a} x #{slug_b}")
      Enum.each(shared_paths, fn path -> IO.puts("    #{path}") end)
    end)

    IO.puts("")
  end

  defp print_disjoint([]) do
    IO.puts(IO.ANSI.bright() <> "DISJOINT (0 pitches)" <> IO.ANSI.reset())
    IO.puts("")
  end

  defp print_disjoint(disjoint) do
    IO.puts(
      IO.ANSI.bright() <>
        "DISJOINT (#{length(disjoint)} #{pitch_noun(length(disjoint))}, safe to run in parallel)" <>
        IO.ANSI.reset()
    )

    IO.puts("  " <> Enum.join(disjoint, ", "))
    IO.puts("")
  end

  defp print_unrouted([]) do
    IO.puts(IO.ANSI.bright() <> "UNROUTED (0 pitches)" <> IO.ANSI.reset())
  end

  defp print_unrouted(unrouted) do
    IO.puts(
      IO.ANSI.bright() <>
        "UNROUTED (#{length(unrouted)} #{pitch_noun(length(unrouted))} — no scope: field; a human must place these)" <>
        IO.ANSI.reset()
    )

    IO.puts("  " <> Enum.join(unrouted, ", "))
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp pitch_noun(1), do: "pitch"
  defp pitch_noun(_), do: "pitches"
end
