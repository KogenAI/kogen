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
  - `--fleet-safe` — optional boolean flag. REQUIRES both `--lanes` and
    `--json` (absent either → exit 2, naming the constraint). When
    given, delegates to `LoopQueue.fleet_partition/3` instead of
    `LoopQueue.partition/2` and emits a FOURTH JSON key,
    `dependency_bound`, alongside the existing three:
    `{"lanes":[[slug,...],...],"global_hot":[slug,...],"unrouted":[slug,...],"dependency_bound":[slug,...]}`.
    A component is `dependency_bound` (held out of every lane) when it
    has an outgoing `blocks_on:` edge (including to a dependency absent
    from this batch — the crux difference from plain `--json`, which
    silently ignores such a dead edge), is named in
    `--externally-referenced`, or shares a `scope:` collision with
    either. Without `--fleet-safe`, output is BYTE-IDENTICAL to the
    pre-existing three-key `--json` shape — this flag is strictly
    additive.
  - `--externally-referenced` — optional comma-separated slug list.
    Only valid alongside `--fleet-safe`. Names slugs that some
    fleet-ready pitch, on ANY node, lists as its `blocks_on:`
    dependency — i.e. slugs this batch must keep local because another
    node's ready pitch depends on them. Malformed (e.g. embedded
    whitespace-only entries are trimmed and dropped; there is no other
    malformed shape) never raises; absent defaults to no external
    references.
  - `--check` — optional boolean flag. Absent: behavior/output/exit
    code are byte-identical to today. Present: runs three independent
    failure-class checks, in order, before any of the normal report
    sections are printed:

    1. UNROUTED — if `scope_report/1` reports any UNROUTED pitch,
       prints the offending slug(s) to stderr and `exit({:shutdown,
       2})`. A `scope: []` pitch (explicit empty list) is DISJOINT, not
       UNROUTED, and passes.
    2. SUBSUMED — if `LoopQueue.subsumed_report/1` reports any pair
       whose `scope:` is a subset of (or equal to) another's with
       neither declaring `split_subject:`, prints the offending pair(s)
       to stderr and `exit({:shutdown, 2})` — see
       `codegen/pitches/ready/a-split-pitch-must-be-two-real-bets.md`.
       A pitch clears this check by recording `split_subject: <clause
       A>; <clause B>` in its own frontmatter (either sibling
       declaring it clears the pair).
    3. HANDOFF GAP — only when `--slug` is given: if the named pitch's
       `handoffs:` records fail `LoopQueue.reconcile_handoffs/4`
       (missing counterpart, mismatched copy, or owner-scope gap),
       prints `HANDOFF GAP <delta-id>: <reason>` to stderr and
       `exit({:shutdown, 2})` — see `--slug`/`--stamp-handoff-receipt`
       below.

    This is the `make test` / `pitch-scope-parity` gate leg: every
    pitch promoted to `ready/` must declare a `scope:` field, and a
    pitch whose scope is subsumed by another's must prove it is a
    genuinely separate bet.
  - `--slug` — optional, requires `--check`. Scopes the UNROUTED/
    SUBSUMED checks AND the HANDOFF GAP check to the single named
    pitch (resolved by scanning `draft/`, `ready/`, and `shipped/`
    under `<cwd>/codegen/pitches/` for `<slug>.md`; zero or more than
    one match is an error naming the value). Without `--slug`, the
    HANDOFF GAP check does not run — legacy behavior is unchanged.
  - `--stamp-handoff-receipt` — optional boolean flag, requires
    `--check --slug`. After the named pitch's `handoffs:` records
    reconcile cleanly, mints/refreshes `handoff_receipt:` in EVERY
    DRAFT participant of the connected component (via
    `LoopQueue.write_handoff_receipt!/3`'s compare-and-swap write) —
    already-`ready/`/`shipped/` participants are treated as
    possession-controlled, read-only inputs and are never written.
    Refuses (`exit({:shutdown, 2})`, writes nothing) when any local
    participant is currently in `building/` — a possession-controlled
    pitch mid-cycle must not be rewritten out from under the loop.

  ## Exit codes (handoff-specific)

  - `--stamp-handoff-receipt` without `--check --slug` → exit 2 naming
    the constraint
  - HANDOFF GAP on the named pitch's reconciliation → exit 2, message
    prefixed `HANDOFF GAP <delta-id>:`
  - a local `building/` participant found during stamping → exit 2
    naming the participant slug

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
    silently returning an empty/wrong partition), a pitch's
    `split_subject:` value is present but not two-clause shaped
    (`LoopQueue.parse_split_subject/2` raises loud), `--dir` names an
    unrecognized value, `--lanes` is not a positive integer, `--json`
    is given without `--lanes`, `--check` is given and the scanned dir
    has at least one UNROUTED pitch or SUBSUMED pair, `--slug` does not
    resolve to exactly one pitch, `--stamp-handoff-receipt` is given
    without `--check --slug`, or (see § HANDOFF GAP above) the named
    pitch's `handoffs:` records fail reconciliation
  """

  use Mix.Task

  alias CodegenTestHarness.LoopQueue

  @valid_dirs ~w(ready draft shipped)

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, _positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          dir: :string,
          cwd: :string,
          lanes: :string,
          check: :boolean,
          json: :boolean,
          fleet_safe: :boolean,
          externally_referenced: :string,
          slug: :string,
          stamp_handoff_receipt: :boolean
        ]
      )

    if invalid != [] do
      Mix.shell().error("codegen.pitches.scope: invalid flags: #{inspect(invalid)}")
      exit({:shutdown, 2})
    end

    dir_name = Keyword.get(opts, :dir, "ready")
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    lanes_raw = Keyword.get(opts, :lanes)
    slug = Keyword.get(opts, :slug)
    stamp_handoff_receipt? = Keyword.get(opts, :stamp_handoff_receipt, false)
    check? = Keyword.get(opts, :check, false)

    if stamp_handoff_receipt? and not (check? and is_binary(slug)) do
      Mix.shell().error("codegen.pitches.scope: --stamp-handoff-receipt requires --check --slug")

      exit({:shutdown, 2})
    end

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

    fleet_safe? = Keyword.get(opts, :fleet_safe, false)
    externally_referenced_raw = Keyword.get(opts, :externally_referenced)

    if fleet_safe? and (is_nil(lane_count) or not json?) do
      Mix.shell().error("codegen.pitches.scope: --fleet-safe requires both --lanes and --json")

      exit({:shutdown, 2})
    end

    if not fleet_safe? and not is_nil(externally_referenced_raw) do
      Mix.shell().error(
        "codegen.pitches.scope: --externally-referenced is only valid alongside --fleet-safe"
      )

      exit({:shutdown, 2})
    end

    externally_referenced = parse_externally_referenced(externally_referenced_raw)

    pitches_dir = Path.join([cwd, "codegen", "pitches", dir_name]) |> Path.expand()

    unless File.dir?(pitches_dir) do
      IO.puts("no pitches in #{pitches_dir}")
      exit(:normal)
    end

    {disjoint, collisions, unrouted} = LoopQueue.scope_report(pitches_dir)

    if check? and unrouted != [] do
      Mix.shell().error(
        "codegen.pitches.scope --check: #{length(unrouted)} unrouted " <>
          "#{pitch_noun(length(unrouted))} in #{pitches_dir} (missing scope: field): " <>
          Enum.join(unrouted, ", ")
      )

      exit({:shutdown, 2})
    end

    if check? do
      subsumed = LoopQueue.subsumed_report(pitches_dir)

      if subsumed != [] do
        Mix.shell().error(
          "codegen.pitches.scope --check: #{length(subsumed)} subsumed " <>
            "#{pitch_noun(length(subsumed))} pair#{plural(length(subsumed))} — " <>
            Enum.map_join(subsumed, "; ", fn {subsumed_slug, superset_slug} ->
              "#{subsumed_slug} scope ⊆ #{superset_slug} scope, neither declares split_subject:"
            end)
        )

        exit({:shutdown, 2})
      end
    end

    if check? and is_binary(slug) do
      run_handoff_check!(cwd, slug, stamp_handoff_receipt?)
    end

    cond do
      json? and fleet_safe? ->
        emit_fleet_json(pitches_dir, lane_count, externally_referenced)

      json? ->
        emit_json(pitches_dir, lane_count)

      true ->
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

  defp emit_fleet_json(pitches_dir, lane_count, externally_referenced) do
    {lanes, global_hot, unrouted, dependency_bound} =
      LoopQueue.fleet_partition(pitches_dir, lane_count, externally_referenced)

    IO.puts(
      Jason.encode!(%{
        lanes: lanes,
        global_hot: global_hot,
        unrouted: unrouted,
        dependency_bound: dependency_bound
      })
    )
  end

  defp parse_externally_referenced(nil), do: MapSet.new()

  defp parse_externally_referenced(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  # Resolves `slug`'s pitch file by scanning draft/, ready/, and shipped/
  # under `cwd/codegen/pitches/` — a `--slug` may name a draft not-yet-
  # promoted counterpart as well as the ready pitch being checked.
  @spec pitches_search_dirs(String.t()) :: [String.t()]
  defp pitches_search_dirs(cwd) do
    Enum.map(@valid_dirs, fn d -> Path.join([cwd, "codegen", "pitches", d]) |> Path.expand() end)
  end

  @spec resolve_slug_path!(String.t(), String.t()) :: String.t()
  defp resolve_slug_path!(cwd, slug) do
    matches =
      cwd
      |> pitches_search_dirs()
      |> Enum.map(&Path.join(&1, "#{slug}.md"))
      |> Enum.filter(&File.exists?/1)

    case matches do
      [path] ->
        path

      [] ->
        Mix.shell().error(
          "codegen.pitches.scope: --slug #{inspect(slug)} did not resolve to any pitch " <>
            "under #{inspect(pitches_search_dirs(cwd))}"
        )

        exit({:shutdown, 2})

      many ->
        Mix.shell().error(
          "codegen.pitches.scope: --slug #{inspect(slug)} resolved to more than one " <>
            "pitch: #{inspect(many)}"
        )

        exit({:shutdown, 2})
    end
  end

  # Runs the HANDOFF GAP check (and, when requested, the stamp) for `slug`.
  # Reconciliation failure and stamp failure both exit({:shutdown, 2}) with
  # the reason on stderr — this task never prints a partial/best-effort
  # handoff verdict.
  @spec run_handoff_check!(String.t(), String.t(), boolean()) :: :ok
  defp run_handoff_check!(cwd, slug, stamp_handoff_receipt?) do
    pitch_path = resolve_slug_path!(cwd, slug)
    dirs = pitches_search_dirs(cwd)

    case LoopQueue.reconcile_handoffs(slug, pitch_path, dirs) do
      :ok ->
        if stamp_handoff_receipt? do
          stamp_handoff_receipts!(cwd, slug, pitch_path, dirs)
        else
          :ok
        end

      {:error, reason} ->
        Mix.shell().error("codegen.pitches.scope --check: #{reason}")
        exit({:shutdown, 2})
    end
  end

  # Stamps handoff_receipt: into every DRAFT participant of `slug`'s
  # connected component. `ready/`/`shipped/` participants are possession-
  # controlled, read-only inputs — never written. A local `building/`
  # participant refuses the whole stamp (nothing written) since it is
  # mid-cycle and must not be rewritten out from under the loop.
  @spec stamp_handoff_receipts!(String.t(), String.t(), String.t(), [String.t()]) :: :ok
  defp stamp_handoff_receipts!(cwd, slug, pitch_path, dirs) do
    building_dir = Path.join([cwd, "codegen", "pitches", "building"]) |> Path.expand()
    component = handoff_component(slug, pitch_path, dirs)

    Enum.each(component, fn {component_slug, _path} ->
      building_path = Path.join(building_dir, "#{component_slug}.md")

      if File.exists?(building_path) do
        Mix.shell().error(
          "codegen.pitches.scope --stamp-handoff-receipt: participant " <>
            "#{inspect(component_slug)} is in building/ — refusing to stamp"
        )

        exit({:shutdown, 2})
      end
    end)

    Enum.each(component, fn {component_slug, component_path} ->
      draft_dir = Path.join([cwd, "codegen", "pitches", "draft"]) |> Path.expand()

      if Path.dirname(component_path) == draft_dir do
        {:ok, records} = LoopQueue.parse_handoffs(component_slug, component_path)
        receipt = LoopQueue.handoff_receipt(component_slug, records || [])
        content = File.read!(component_path)

        case LoopQueue.write_handoff_receipt!(component_path, content, receipt) do
          :ok ->
            :ok

          {:error, :stale} ->
            Mix.shell().error(
              "codegen.pitches.scope --stamp-handoff-receipt: #{inspect(component_slug)} " <>
                "changed on disk mid-stamp — aborting; retry"
            )

            exit({:shutdown, 2})
        end
      end
    end)

    :ok
  end

  # Walks the connected component of `slug` (every pitch reachable via a
  # handoffs: record, transitively) and returns `[{slug, resolved_path},
  # ...]` — the exact set stamp_handoff_receipts!/4 must consider.
  @spec handoff_component(String.t(), String.t(), [String.t()]) :: [{String.t(), String.t()}]
  defp handoff_component(slug, pitch_path, dirs) do
    walk_handoff_component([{slug, pitch_path}], dirs, MapSet.new())
  end

  defp walk_handoff_component([], _dirs, _visited), do: []

  defp walk_handoff_component([{slug, path} | rest], dirs, visited) do
    if MapSet.member?(visited, slug) do
      walk_handoff_component(rest, dirs, visited)
    else
      visited = MapSet.put(visited, slug)
      {:ok, records} = LoopQueue.parse_handoffs(slug, path)

      neighbors =
        (records || [])
        |> Enum.map(fn r -> if slug == r.source, do: r.owner, else: r.source end)
        |> Enum.uniq()
        |> Enum.map(fn neighbor_slug ->
          {neighbor_slug, find_in_dirs(neighbor_slug, dirs)}
        end)
        |> Enum.reject(fn {_s, p} -> is_nil(p) end)

      [{slug, path} | walk_handoff_component(rest ++ neighbors, dirs, visited)]
    end
  end

  defp find_in_dirs(slug, dirs) do
    Enum.find_value(dirs, fn dir ->
      candidate = Path.join(dir, "#{slug}.md")
      if File.exists?(candidate), do: candidate
    end)
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
        IO.puts(
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
