defmodule Mix.Tasks.Codegen.Pitches.Scope do
  @shortdoc "Reports scope: collisions/disjoint/unrouted across a pitch batch"

  @moduledoc """
  `mix codegen.pitches.scope [--dir=ready] [--cwd=.] [--lanes=N]`

  Deterministic, offline reader over the `scope:` frontmatter field (see
  `codegen/pitches/ready/a-pitch-declares-the-files-it-will-touch.md`).
  Answers "which pitches in this batch touch the same files?" without an
  LLM call — the operator question this task exists to make answerable.

  Delegates entirely to `CodegenTestHarness.LoopQueue.scope_report/1`
  (default output) and `LoopQueue.partition/2` (when `--lanes` is
  given). This task is I/O + formatting only; without `--check` it adds
  no gate and no retire behavior — it is a report, not a scheduler.
  `--lanes` prints a paste-ready partition; nothing is written or
  applied (see
  `codegen/pitches/ready/drain-partitions-lanes-by-edit-surface.md`).
  With `--check`, it IS a gate: it fails loud when any pitch in the
  scanned dir is UNROUTED (see `--check` under Flags and Exit codes).

  ## Flags

  - `--dir` — optional, one of `ready` | `draft` | `shipped` (default
    `ready`) — resolved relative to `<cwd>/codegen/pitches/`
  - `--cwd` — optional, project root whose `codegen/pitches/<dir>/` is
    scanned (default `File.cwd!/0`, the directory `mix` was invoked
    from)
  - `--lanes` — optional positive integer. Absent: output is
    byte-identical to the pre-`--lanes` report (COLLISIONS/DISJOINT/
    UNROUTED only). Present: additionally prints `LANE 1..N`,
    `GLOBAL-HOT`, and `UNROUTED` sections from `LoopQueue.partition/2`.
  - `--json` — optional boolean flag. Requires `--lanes` (absent
    `--lanes` → exit 2, naming the constraint — JSON output IS the
    partition, and without a lane count there is no partition to
    serialize). When both are given, replaces ALL prose sections
    (COLLISIONS/DISJOINT/LANE/GLOBAL-HOT/UNROUTED) with a single line
    of `Jason.encode!/1` JSON on stdout:
    `{"lanes":[[slug,...],...],"global_hot":[slug,...],"unrouted":[slug,...]}`.
    No `IO.ANSI` escapes, no `Mix.shell()` prose — this is the
    machine-readable leg a caller (e.g. `codegen-drain assign --auto`)
    parses. Mirrors the existing `codegen-drain status --json` shape
    convention.
  - `--check` — optional boolean flag. Absent: behavior/output/exit
    code are byte-identical to today. Present: if `scope_report/1`
    reports any UNROUTED pitch, prints the offending slug(s) to stderr
    and `exit({:shutdown, 2})` BEFORE any of the normal report sections
    are printed. A `scope: []` pitch (explicit empty list) is DISJOINT,
    not UNROUTED, and passes. This is the `make test` /
    `pitch-scope-parity` gate leg: every pitch promoted to `ready/`
    must declare a `scope:` field.

  ## Output

  Without `--lanes`, three sections:

    - `COLLISIONS` — pairs of pitches whose `scope:` lists share at
      least one path, and the shared paths
    - `DISJOINT` — scoped pitches sharing no file with any other scoped
      pitch in the batch — safe to route to different machines/lanes
    - `UNROUTED` — pitches with no `scope:` field at all — a human must
      place these; absence is reported, never guessed at

  With `--lanes=N`, the COLLISIONS/DISJOINT sections are followed by:

    - `LANE 1..N` — ordered slug lists, one per lane, size-balanced by
      `scope:` file count; a lane's slugs never split a collision
      component across two lanes
    - `GLOBAL-HOT` — slugs whose component collides with every lane;
      never placed — build these alone
    - `UNROUTED` — pitches with no `scope:` field; never placed

  ## Exit codes

  - `0` — report printed (including the all-empty / all-unrouted case,
    and the `--lanes=N` > routable-pitch-count case, which prints
    fewer lanes and says so)
  - non-zero — a pitch's `scope:` value is present but not a parseable
    `[...]` flow-list (`LoopQueue.parse_scope/2` raises loud rather than
    silently returning an empty/wrong partition), `--dir` names an
    unrecognized value, `--lanes` is not a positive integer, `--json`
    is given without `--lanes`, or `--check` is given and the scanned
    dir has at least one UNROUTED pitch
  """

  use Mix.Task

  alias CodegenTestHarness.LoopQueue

  @valid_dirs ~w(ready draft shipped)

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, _positional, invalid} =
      OptionParser.parse(argv,
        strict: [dir: :string, cwd: :string, lanes: :string, check: :boolean, json: :boolean]
      )

    if invalid != [] do
      Mix.shell().error("codegen.pitches.scope: invalid flags: #{inspect(invalid)}")
      exit({:shutdown, 2})
    end

    dir_name = Keyword.get(opts, :dir, "ready")
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    lanes_raw = Keyword.get(opts, :lanes)

    unless dir_name in @valid_dirs do
      Mix.shell().error(
        "codegen.pitches.scope: --dir must be one of #{inspect(@valid_dirs)}, got #{inspect(dir_name)}"
      )

      exit({:shutdown, 2})
    end

    lane_count = parse_lane_count!(lanes_raw)
    json? = Keyword.get(opts, :json, false)

    if json? and is_nil(lane_count) do
      Mix.shell().error(
        "codegen.pitches.scope: --json requires --lanes — JSON output IS the " <>
          "partition, and without a lane count there is no partition to serialize"
      )

      exit({:shutdown, 2})
    end

    pitches_dir = Path.join([cwd, "codegen", "pitches", dir_name]) |> Path.expand()

    unless File.dir?(pitches_dir) do
      Mix.shell().info("no pitches in #{pitches_dir}")
      exit(:normal)
    end

    {disjoint, collisions, unrouted} = LoopQueue.scope_report(pitches_dir)

    if Keyword.get(opts, :check, false) and unrouted != [] do
      Mix.shell().error(
        "codegen.pitches.scope --check: #{length(unrouted)} unrouted " <>
          "#{pitch_noun(length(unrouted))} in #{pitches_dir} (missing scope: field): " <>
          Enum.join(unrouted, ", ")
      )

      exit({:shutdown, 2})
    end

    if json? do
      emit_json(pitches_dir, lane_count)
    else
      print_collisions(collisions)
      print_disjoint(disjoint)

      if lane_count do
        print_lanes(pitches_dir, lane_count)
      else
        print_unrouted(unrouted)
      end
    end
  end

  defp emit_json(pitches_dir, lane_count) do
    {lanes, global_hot, unrouted} = LoopQueue.partition(pitches_dir, lane_count)

    IO.puts(Jason.encode!(%{lanes: lanes, global_hot: global_hot, unrouted: unrouted}))
  end

  defp parse_lane_count!(nil), do: nil

  defp parse_lane_count!(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 ->
        n

      _ ->
        Mix.shell().error(
          "codegen.pitches.scope: --lanes must be a positive integer, got #{inspect(raw)}"
        )

        exit({:shutdown, 2})
    end
  end

  defp print_lanes(pitches_dir, lane_count) do
    {lanes, global_hot, unrouted} = LoopQueue.partition(pitches_dir, lane_count)

    routable_count = lanes |> List.flatten() |> length()

    print_lanes =
      if routable_count < lane_count do
        Mix.shell().info(
          "#{lane_count} lanes requested; only #{routable_count} routable " <>
            "#{pitch_noun(routable_count)} — printing #{routable_count}"
        )

        IO.puts("")

        Enum.reject(lanes, &(&1 == []))
      else
        lanes
      end

    print_lanes
    |> Enum.with_index(1)
    |> Enum.each(fn {lane_slugs, idx} ->
      size = lane_scope_size(pitches_dir, lane_slugs)

      IO.puts(
        IO.ANSI.bright() <>
          "LANE #{idx} (#{length(lane_slugs)} #{pitch_noun(length(lane_slugs))}, #{size} scope files)" <>
          IO.ANSI.reset()
      )

      if lane_slugs == [] do
        IO.puts("  (empty)")
      else
        IO.puts("  " <> Enum.join(lane_slugs, ", "))
      end

      IO.puts("")
    end)

    print_global_hot(global_hot)
    print_unrouted(unrouted)
  end

  defp lane_scope_size(pitches_dir, lane_slugs) do
    lane_slugs
    |> Enum.flat_map(fn slug ->
      case LoopQueue.parse_scope(slug, Path.join(pitches_dir, "#{slug}.md")) do
        {:ok, nil} -> []
        {:ok, paths} -> paths
      end
    end)
    |> Enum.uniq()
    |> length()
  end

  defp print_global_hot([]) do
    IO.puts(IO.ANSI.bright() <> "GLOBAL-HOT (0 pitches)" <> IO.ANSI.reset())
    IO.puts("")
  end

  defp print_global_hot(global_hot) do
    IO.puts(
      IO.ANSI.bright() <>
        "GLOBAL-HOT (#{length(global_hot)} #{pitch_noun(length(global_hot))} — collides with every lane; build alone)" <>
        IO.ANSI.reset()
    )

    IO.puts("  " <> Enum.join(global_hot, ", "))
    IO.puts("")
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
