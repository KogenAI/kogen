defmodule CodegenTestHarness.LoopQueue do
  @moduledoc """
  Absorbs `harnesses/shared/build-queue.sh`'s pure-logic pieces: scans
  `codegen/pitches/ready/` pitch files, topologically sorts their
  dependency edges (Kahn's algorithm, deps first), and classifies a
  captured console capture as a transient (retryable) infra blip via
  `retryable_regex` (ported from `harnesses/shared/retryable-errors.sh`).

  Dependency edges are read from a pitch's `blocks_on: [a, b]` YAML
  frontmatter list when a leading `---`...`---` frontmatter block is
  present (dual-read: frontmatter wins when present). Pitches with no
  frontmatter fall back to the legacy prose parse (`Blocks-on:` lines /
  `## Dependencies` bullet lists) — this keeps pre-existing pitches
  without frontmatter working unchanged.

  Process-orchestration concerns owned by the shell script (queue lock,
  watchdog, per-pitch wall-clock budget, `build-queue.json` position) are
  NOT ported here — `OrchestrationLoop`/`Mix.Tasks.Codegen.Loop` drive one
  pitch per invocation; multi-pitch draining is the caller's concern.

  Crashes loud (raises) on a dependency cycle — never silently drops a
  pitch or picks an arbitrary order.
  """

  @type slug :: String.t()
  @type edge :: {slug(), slug()}
  @type blocked_map :: %{slug() => slug()}

  @retryable_regex ~r/Stream idle timeout|Unable to connect|FailedToOpenSocket|ConnectionRefused|API Error: 529|API Error: 500|API Error: 502|API Error: 503|API Error: 504|overloaded_error|Internal server error|upstream connect error|connection reset|socket hang up|ETIMEDOUT|context deadline exceeded|File has been modified since read|has been unexpectedly modified|socket connection was closed|Connection closed mid-response/

  # switch_model_regex ported from harnesses/shared/retryable-errors.sh — the
  # MODEL is down/gone, not a transport blip. Distinct from @retryable_regex:
  # retrying the SAME model is pointless here; the caller
  # (OrchestrationLoop.do_invoke_attempt/6) walks the role's `fallback:` chain
  # instead. Case-insensitive to match both "Model X is currently unavailable"
  # and "model unavailable" phrasing.
  @switch_model_regex ~r/model.*unavailable|provider.*unavailable|model.*disabled|model.*not found|unknown model|is currently unavailable/i

  @doc """
  Returns the `.md` slugs (basenames without extension) under `ready_dir`,
  topologically ordered so that a pitch's `Blocks-on:` dependencies come
  before it. Edges whose dependency is NOT present in `ready_dir` are
  ignored (matches `build-queue.sh` behavior — only intra-batch edges
  constrain ordering).

  Raises on a dependency cycle among the batch.

  `exclude` (default `MapSet.new()`) — slugs to treat as ABSENT from
  `ready_dir` even though the file physically exists there. Used by
  `LoopQueueDrain`'s `--watch` quiescence gate: a pitch mid-`scp` (mtime
  newer than the quiesce window) is excluded from both the returned order
  AND, critically, as a dependency-satisfying presence for any dependent —
  see `blocked_by_unmet_dep/3`'s matching `exclude` param, which MUST be
  called with the SAME set so a half-written dep never satisfies its
  dependent's edge.
  """
  @spec ordered_slugs(String.t(), MapSet.t(slug())) :: [slug()]
  def ordered_slugs(ready_dir, exclude \\ MapSet.new()) do
    slugs =
      ready_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".md"))
      |> Enum.reject(&MapSet.member?(exclude, &1))
      |> Enum.sort()

    edges =
      slugs
      |> Enum.flat_map(fn slug ->
        parse_edges(slug, Path.join(ready_dir, "#{slug}.md"))
      end)
      |> Enum.filter(fn {_slug, dep} -> dep in slugs end)

    topo_sort(slugs, edges)
  end

  @doc """
  Parses dependency edges out of the pitch file at `pitch_path`, returning
  `{slug, dep}` edge tuples (`slug` depends on/is blocked by `dep`).

  Frontmatter-first: when the file opens with a `---`...`---` block
  containing a `blocks_on:` key, that flow-list is the sole edge source
  (legacy prose in the body is ignored). Otherwise falls back to parsing
  `Blocks-on:` lines / `## Dependencies` bullet lists from the body.

  Returns `[]` if `pitch_path` does not exist (mirrors the shell's silent
  no-op via `2>/dev/null || true`).
  """
  @spec parse_edges(slug(), String.t()) :: [edge()]
  def parse_edges(slug, pitch_path) do
    if File.exists?(pitch_path) do
      content = File.read!(pitch_path)

      case frontmatter_block(content) do
        nil ->
          content
          |> String.split("\n")
          |> parse_edge_lines(slug, false)

        block ->
          block
          |> parse_frontmatter_blocks_on()
          |> Enum.map(&{slug, &1})
      end
    else
      []
    end
  end

  @doc """
  Parses the `scope:` frontmatter field out of the pitch file at
  `pitch_path` — repo-relative paths this pitch will edit (see
  `codegen/pitches/ready/a-pitch-declares-the-files-it-will-touch.md`).

  Reuses the SAME multiline-capable frontmatter reader as
  `parse_edges/2`'s `blocks_on:` parse (`extract_frontmatter_key/2`) —
  `scope:`'s only hand-written instance in the corpus is multiline (a
  path list rarely fits inline), so multiline is the norm here, not an
  edge case.

  Returns:

    - `{:ok, [path, ...]}` — `scope:` present and a well-formed flow-list
      (possibly empty, `scope: []`)
    - `{:ok, nil}` — no `scope:` key, or no frontmatter block at all —
      the documented "unrouted" sentinel, not an error
    - raises — `scope:` key present but its value is not a parseable
      `[...]` flow-list (e.g. a bare scalar). A confidently-wrong empty
      partition is worse than a loud crash naming the slug.
  """
  @spec parse_scope(slug(), String.t()) :: {:ok, [String.t()] | nil}
  def parse_scope(slug, pitch_path) do
    if File.exists?(pitch_path) do
      content = File.read!(pitch_path)

      case frontmatter_block(content) do
        nil ->
          {:ok, nil}

        block ->
          case extract_frontmatter_key(block, "scope:") do
            "" ->
              {:ok, nil}

            raw ->
              case parse_flow_list_strict(raw) do
                {:ok, paths} ->
                  {:ok, paths}

                :error ->
                  raise "LoopQueue.parse_scope: #{slug} has a scope: value that is " <>
                          "not a parseable [...] flow-list: #{inspect(raw)}"
              end
          end
      end
    else
      {:ok, nil}
    end
  end

  # Like parse_flow_list/1 but distinguishes "not a flow-list at all"
  # (:error, for parse_scope/2's loud raise) from "flow-list, possibly
  # empty" ({:ok, list}). parse_flow_list/1 keeps its own [] collapse
  # for blocks_on:'s dual-read semantics (absent == no deps, unchanged).
  @spec parse_flow_list_strict(String.t()) :: {:ok, [String.t()]} | :error
  defp parse_flow_list_strict(value) do
    trimmed = String.trim(value)

    case Regex.run(~r/^\[(.*)\]$/s, trimmed) do
      [_, inner] ->
        paths =
          inner
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.map(&unquote_flow_item/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, paths}

      _ ->
        :error
    end
  end

  @doc """
  Scans the `.md` slugs under `pitches_dir` and returns
  `{disjoint, collisions, unrouted}`:

    - `disjoint` — slugs whose `scope:` paths share no file with any
      other scoped pitch in the batch
    - `collisions` — `{slug_a, slug_b, shared_paths}` triples for every
      pair of scoped pitches sharing at least one path
    - `unrouted` — slugs with no `scope:` field (or empty frontmatter)

  Pure/deterministic — no LLM, no network. A pitch with `scope: []`
  (present, explicitly empty) is DISJOINT (it declares it touches
  nothing), not unrouted — only a genuinely ABSENT key is unrouted.
  """
  @spec scope_report(String.t()) ::
          {disjoint :: [slug()], collisions :: [{slug(), slug(), [String.t()]}],
           unrouted :: [slug()]}
  def scope_report(pitches_dir) do
    slugs =
      pitches_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".md"))
      |> Enum.sort()

    scoped =
      Enum.reduce(slugs, %{}, fn slug, acc ->
        case parse_scope(slug, Path.join(pitches_dir, "#{slug}.md")) do
          {:ok, nil} -> acc
          {:ok, paths} -> Map.put(acc, slug, paths)
        end
      end)

    unrouted = Enum.reject(slugs, &Map.has_key?(scoped, &1))

    scoped_slugs = scoped |> Map.keys() |> Enum.sort()

    collisions =
      for {slug_a, i} <- Enum.with_index(scoped_slugs),
          slug_b <- Enum.drop(scoped_slugs, i + 1),
          shared = shared_paths(scoped[slug_a], scoped[slug_b]),
          shared != [] do
        {slug_a, slug_b, shared}
      end

    collided_slugs = collisions |> Enum.flat_map(fn {a, b, _} -> [a, b] end) |> MapSet.new()
    disjoint = Enum.reject(scoped_slugs, &MapSet.member?(collided_slugs, &1))

    {disjoint, collisions, unrouted}
  end

  defp shared_paths(paths_a, paths_b) do
    set_a = MapSet.new(paths_a)
    set_b = MapSet.new(paths_b)

    set_a
    |> MapSet.intersection(set_b)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @doc """
  Folds the `scope:` collision graph over `pitches_dir` into `lane_count`
  ordered lanes — the greedy connected-component fold described in
  `codegen/pitches/ready/drain-partitions-lanes-by-edit-surface.md`.

  Builds its OWN scoped map via `parse_scope/2` (does not reuse
  `scope_report/1`'s return — that function discards per-slug scope
  paths, keeping only the derived disjoint/collisions/unrouted lists,
  which is not enough to fold a slug into a specific lane).

  Connected components of the collision graph (edge = at least one
  shared `scope:` path) are computed FIRST, via union-find over the
  scoped slugs. A lane never splits a component — this is what keeps a
  hot cluster whole on one lane and makes cross-lane collision weight
  0 BY CONSTRUCTION, not by a greedy per-pitch tie-break that could
  still split a cluster across two lanes.

  Components are then greedily assigned to lanes: largest (by summed
  `scope:` file count) first, each into whichever lane currently has
  the smallest total scope-file count (a longest-processing-time bin
  fold) — the free size-balance signal already present in the graph
  (no cost estimator, no build-history input).

  A component that shares at least one file with every OTHER
  component (i.e. its own collision-adjacency, not lane membership,
  touches the entire batch) is never placed in a lane — it is
  returned separately as `global_hot`, alone, to be built serially.
  `blocks_on:` edges are honored as CO-LOCATION constraints only (see
  the pitch's Solution sketch: a `blocks_on:` edge is sometimes
  produce/consume and sometimes a shared edit surface, and co-location
  satisfies both readings without the fold needing to distinguish
  them) — a `blocks_on:` pair is merged into the same union-find
  component as any `scope:` collision would be, PROVIDED both ends are
  present as scoped slugs in `pitches_dir` (an edge naming a slug
  outside the scoped batch, e.g. because it already shipped, is a dead
  edge and is silently ignored, matching `ordered_slugs/2`'s existing
  intra-batch-only edge filter).

  Each lane's slugs are ordered with `topo_sort/2` over the lane's own
  `blocks_on:` edges (edges outside the lane are already unreachable —
  co-location guarantees any edge between two scoped slugs lives
  inside one lane).

  Returns `{lanes, global_hot, unrouted}`:

    - `lanes` — `lane_count` lists of slugs (a lane may be `[]` when
      there are fewer components than lanes), each topo-sorted
    - `global_hot` — slugs whose component collides with every lane
      (never placed); `[]` when none
    - `unrouted` — slugs with no `scope:` field (never placed; mirrors
      `scope_report/1`'s UNROUTED)

  Raises when `lane_count` is not a positive integer.
  """
  @spec partition(String.t(), pos_integer()) ::
          {lanes :: [[slug()]], global_hot :: [slug()], unrouted :: [slug()]}
  def partition(pitches_dir, lane_count) when is_integer(lane_count) and lane_count > 0 do
    slugs =
      pitches_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".md"))
      |> Enum.sort()

    scoped =
      Enum.reduce(slugs, %{}, fn slug, acc ->
        case parse_scope(slug, Path.join(pitches_dir, "#{slug}.md")) do
          {:ok, nil} -> acc
          {:ok, paths} -> Map.put(acc, slug, paths)
        end
      end)

    unrouted = Enum.reject(slugs, &Map.has_key?(scoped, &1))
    scoped_slugs = scoped |> Map.keys() |> Enum.sort()

    blocks_edges =
      scoped_slugs
      |> Enum.flat_map(fn slug ->
        parse_edges(slug, Path.join(pitches_dir, "#{slug}.md"))
      end)
      |> Enum.filter(fn {s, dep} -> s in scoped_slugs and dep in scoped_slugs end)

    # GLOBAL-HOT is computed at the raw per-slug collision-adjacency level,
    # BEFORE union-find merging: a slug that shares a scope: path with EVERY
    # other scoped slug. Checking this at the component level (post-merge)
    # would be dead code — any slug colliding with everything else gets
    # union-find-merged INTO one giant component together with them, so no
    # component could ever "collide with every other component" (there
    # would only be one component left). Extracting these hot slugs BEFORE
    # merging, and excluding them from the placeable graph, is what makes
    # GLOBAL-HOT reachable.
    global_hot =
      scoped_slugs
      |> Enum.filter(&collides_with_every_other_slug?(&1, scoped_slugs, scoped))
      |> Enum.sort()

    placeable_slugs = scoped_slugs -- global_hot

    scope_edges =
      for {slug_a, i} <- Enum.with_index(placeable_slugs),
          slug_b <- Enum.drop(placeable_slugs, i + 1),
          shared_paths(scoped[slug_a], scoped[slug_b]) != [] do
        {slug_a, slug_b}
      end

    placeable_blocks_edges =
      Enum.filter(blocks_edges, fn {s, dep} -> s in placeable_slugs and dep in placeable_slugs end)

    all_edges = scope_edges ++ Enum.map(placeable_blocks_edges, fn {s, dep} -> {s, dep} end)

    components = connected_components(placeable_slugs, all_edges)

    lanes =
      components
      |> Enum.sort_by(fn comp -> -component_scope_size(comp, scoped) end)
      |> assign_components_to_lanes(lane_count, scoped)
      |> Enum.map(fn lane_slugs ->
        lane_edges =
          Enum.filter(placeable_blocks_edges, fn {s, dep} ->
            s in lane_slugs and dep in lane_slugs
          end)

        topo_sort(Enum.sort(lane_slugs), lane_edges)
      end)

    {lanes, global_hot, unrouted}
  end

  defp component_scope_size(comp, scoped) do
    comp
    |> Enum.flat_map(&Map.get(scoped, &1, []))
    |> Enum.uniq()
    |> length()
  end

  defp assign_components_to_lanes(sorted_components, lane_count, scoped) do
    initial = List.duplicate([], lane_count)

    {lanes, _sizes} =
      Enum.reduce(sorted_components, {initial, List.duplicate(0, lane_count)}, fn comp,
                                                                                  {lanes, sizes} ->
        target_idx =
          sizes |> Enum.with_index() |> Enum.min_by(fn {size, _idx} -> size end) |> elem(1)

        new_lanes = List.update_at(lanes, target_idx, &(&1 ++ comp))
        new_sizes = List.update_at(sizes, target_idx, &(&1 + component_scope_size(comp, scoped)))

        {new_lanes, new_sizes}
      end)

    lanes
  end

  defp collides_with_every_other_slug?(slug, all_slugs, scoped) do
    others = List.delete(all_slugs, slug)

    others != [] and
      Enum.all?(others, fn other_slug ->
        shared_paths(Map.get(scoped, slug, []), Map.get(scoped, other_slug, [])) != []
      end)
  end

  # Union-find over `slugs` given undirected `edges` (order-insensitive —
  # both scope-collision pairs and blocks_on: pairs are treated as
  # co-location, never as a directed ordering constraint here; ordering
  # within a lane is topo_sort/2's job, run AFTER components are fixed).
  defp connected_components(slugs, edges) do
    parent = Map.new(slugs, &{&1, &1})

    parent =
      Enum.reduce(edges, parent, fn {a, b}, acc ->
        union(acc, a, b)
      end)

    slugs
    |> Enum.group_by(&find(parent, &1))
    |> Map.values()
    |> Enum.map(&Enum.sort/1)
  end

  defp find(parent, slug) do
    case Map.get(parent, slug) do
      ^slug -> slug
      next -> find(parent, next)
    end
  end

  defp union(parent, a, b) do
    root_a = find(parent, a)
    root_b = find(parent, b)

    if root_a == root_b do
      parent
    else
      Map.put(parent, root_a, root_b)
    end
  end

  # Returns the raw text between the opening and closing `---` delimiters
  # when `content` starts with a frontmatter block, else nil. The opening
  # delimiter MUST be the very first line (no leading blank lines).
  #
  # Promoted to public (was defp) for `record_ship/4`, which needs to
  # detect an existing block to insert-or-replace into vs. mint a fresh one.
  @spec frontmatter_block(String.t()) :: String.t() | nil
  def frontmatter_block(content) do
    case String.split(content, "\n", parts: 2) do
      ["---", rest] ->
        case String.split(rest, "\n---", parts: 2) do
          [block, _after] ->
            block

          # fail-loud-exempt: no closing "---" delimiter — the file opens
          # with a bare "---" line but is not a well-formed frontmatter
          # block. Documented "not frontmatter" sentinel for dual-read
          # fallback, not an unexpected condition.
          _ ->
            nil
        end

      # fail-loud-exempt: file does not open with "---" — the documented
      # "no frontmatter present" sentinel for dual-read fallback, not an
      # unexpected condition.
      _ ->
        nil
    end
  end

  @doc """
  Strips a leading YAML frontmatter block (`---`...`---`) from `content`,
  returning the body only. Reuses `frontmatter_block/1`'s grammar so the
  strip and the `blocks_on` parser can never disagree on what counts as
  frontmatter.

  When `content` has no well-formed frontmatter block (absent, or opens
  with a bare `---` but never closes), `content` is returned UNCHANGED —
  documented "not frontmatter" sentinel, dual-read parity with
  `frontmatter_block/1`, not a swallow.
  """
  @spec strip_frontmatter(String.t()) :: String.t()
  def strip_frontmatter(content) do
    case frontmatter_block(content) do
      nil ->
        content

      _block ->
        case String.split(content, "\n---", parts: 2) do
          [_before, after_delim] -> String.trim_leading(after_delim, "\n")
          _ -> content
        end
    end
  end

  # Reads a `blocks_on: [a, b]` flow-list from a frontmatter block body —
  # either the INLINE form (`blocks_on: [a, b]` on one line) or the
  # MULTILINE form (the key alone on one line, `[`/items/`]` on the
  # lines that follow — the only form ever hand-written for `scope:`,
  # see `parse_scope/2`). Absent key, or `blocks_on: []`, returns [].
  @spec parse_frontmatter_blocks_on(String.t()) :: [slug()]
  defp parse_frontmatter_blocks_on(block) do
    block
    |> extract_frontmatter_key("blocks_on:")
    |> parse_flow_list()
  end

  # Extracts the raw value text for `key` (e.g. "blocks_on:" or "scope:")
  # from a frontmatter block, handling BOTH grammars:
  #
  #   - inline:    `key: [a, b]`               -> "[a, b]"
  #   - multiline: `key:` alone, then following
  #                lines up to the next top-level
  #                `other_key:` line or block end -> those lines joined
  #
  # Returns "" when `key` is absent — the documented "no value" sentinel
  # consumed by `parse_flow_list/1`.
  @spec extract_frontmatter_key(String.t(), String.t()) :: String.t()
  defp extract_frontmatter_key(block, key) do
    lines = String.split(block, "\n")

    case Enum.find_index(lines, &frontmatter_key_line?(&1, key)) do
      nil ->
        ""

      idx ->
        line = Enum.at(lines, idx)
        tail = String.trim(String.trim_leading(String.trim(line), key))

        if tail == "" do
          # Multiline form: the key line carries no value — collect
          # every following line up to (not including) the next
          # top-level "word:" line or the end of the block.
          lines
          |> Enum.drop(idx + 1)
          |> Enum.take_while(&(not top_level_key_line?(&1)))
          |> Enum.join("\n")
        else
          tail
        end
    end
  end

  defp frontmatter_key_line?(line, key) do
    String.starts_with?(String.trim(line), key)
  end

  # A "word:" line at the frontmatter's own indentation (no leading
  # whitespace) marks the start of the NEXT top-level key — the
  # boundary that ends a multiline value's continuation lines. Lines
  # indented under the value (e.g. "  test_harness/...,") never match.
  @top_level_key_regex ~r/^[a-zA-Z_][a-zA-Z0-9_]*:/
  defp top_level_key_line?(line), do: Regex.match?(@top_level_key_regex, line)

  defp parse_flow_list(value) do
    trimmed = String.trim(value)

    case Regex.run(~r/^\[(.*)\]$/s, trimmed) do
      [_, inner] ->
        inner
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&unquote_flow_item/1)
        |> Enum.reject(&(&1 == ""))

      # fail-loud-exempt: value is not a "[...]" flow-list — the
      # documented "blocks_on key absent or not a flow-list" sentinel
      # (e.g. bare `blocks_on:` with no value), not an unexpected
      # condition. Dual-read treats this as "no frontmatter deps".
      _ ->
        []
    end
  end

  defp unquote_flow_item(item) do
    item
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp parse_edge_lines(lines, slug, in_deps) do
    lines
    |> Enum.reduce({[], in_deps}, fn line, {acc, in_deps} ->
      cond do
        String.starts_with?(line, "Blocks-on:") ->
          dep = extract_blocks_on_dep(line)
          {maybe_prepend(acc, slug, dep), in_deps}

        String.starts_with?(line, "## Dependencies") ->
          {acc, true}

        String.starts_with?(line, "## ") ->
          {acc, false}

        in_deps and String.starts_with?(line, "- ") ->
          dep = extract_bullet_dep(line)
          {maybe_prepend(acc, slug, dep), in_deps}

        true ->
          {acc, in_deps}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp maybe_prepend(acc, _slug, nil), do: acc
  defp maybe_prepend(acc, _slug, ""), do: acc
  defp maybe_prepend(acc, slug, dep), do: [{slug, dep} | acc]

  @dep_token_regex ~r/[a-z0-9][a-z0-9-]*/
  @bare_slug_regex ~r/^[a-z0-9-]+$/

  # "Blocks-on: foo — comment", "Blocks-on: (none — independent)",
  # "Blocks-on: `foo`", "Blocks-on: none." → first bare slug token, or ""
  # when the token is the "none" sentinel or absent entirely.
  defp extract_blocks_on_dep(line) do
    rest = String.replace_prefix(line, "Blocks-on:", "")

    case Regex.run(@dep_token_regex, rest) do
      [token] when token != "none" ->
        token

      # fail-loud-exempt: no dep token present (bare "Blocks-on: none" /
      # "(none — independent root)") is the documented "no dependency"
      # sentinel, not an unexpected condition — enumerated by convention C
      # in the pitch (widely used "no deps" idiom).
      _ ->
        ""
    end
  end

  # "- foo" (bare slug bullet) → "foo"; a prose bullet
  # ("- **Depends on `foo`** — SHIPPED") is annotation, not an edge → "".
  defp extract_bullet_dep(line) do
    dep =
      line
      |> String.replace_prefix("- ", "")
      |> String.trim()

    if dep != "none" and Regex.match?(@bare_slug_regex, dep) do
      dep
    else
      ""
    end
  end

  @doc """
  Scans the `.md` slugs under `ready_dir` and returns a map of
  `slug => dep` for every ready pitch whose FIRST `Blocks-on:`/`##
  Dependencies` dependency is unsatisfied.

  A dep is satisfied iff it is present in `ready_dir` (intra-batch — `topo_sort`
  will order it before its dependent) OR present in `shipped_dir` (already
  built). A dep in draft/ or absent entirely is UNSATISFIED — its dependent
  slug is BLOCKED and appears in the returned map.

  Pitches with no unmet dep are absent from the map (not included with a
  `nil`/empty value — absence IS the "not blocked" signal).

  `exclude` (default `MapSet.new()`) — slugs to treat as ABSENT from
  `ready_dir`, both as a scanned pitch (never appears as a map key) AND as
  a dependency-satisfying presence for any OTHER pitch's edge (a dependent
  whose sole dep is excluded is BLOCKED, not satisfied). See
  `ordered_slugs/2` — callers MUST pass the identical `exclude` set to both
  functions so a quiesced-out dep is invisible everywhere at once, not just
  dropped from the returned order while still silently satisfying edges.
  """
  @spec blocked_by_unmet_dep(String.t(), String.t(), MapSet.t(slug())) :: blocked_map()
  def blocked_by_unmet_dep(ready_dir, shipped_dir, exclude \\ MapSet.new()) do
    ready_slugs =
      ready_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".md"))
      |> Enum.reject(&MapSet.member?(exclude, &1))

    ready_set = MapSet.new(ready_slugs)

    shipped_set =
      shipped_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".md"))
      |> MapSet.new()

    ready_slugs
    |> Enum.reduce(%{}, fn slug, acc ->
      edges = parse_edges(slug, Path.join(ready_dir, "#{slug}.md"))

      first_unmet =
        Enum.find_value(edges, fn {_slug, dep} ->
          if MapSet.member?(ready_set, dep) or MapSet.member?(shipped_set, dep) do
            nil
          else
            dep
          end
        end)

      if first_unmet, do: Map.put(acc, slug, first_unmet), else: acc
    end)
  end

  @doc """
  Kahn's-algorithm topological sort of `slugs` given `edges` (`{slug, dep}`
  pairs meaning `slug` is blocked by `dep`; `dep` must be emitted first).

  Raises `RuntimeError` naming the remaining slugs on a cycle.
  """
  @spec topo_sort([slug()], [edge()]) :: [slug()]
  def topo_sort(slugs, edges) do
    do_topo_sort(slugs, edges, [])
  end

  defp do_topo_sort([], _edges, ordered), do: Enum.reverse(ordered)

  defp do_topo_sort(remaining, edges, ordered) do
    remaining_set = MapSet.new(remaining)

    {ready, blocked} =
      Enum.split_with(remaining, fn slug ->
        not blocked_by_remaining?(slug, edges, remaining_set)
      end)

    if ready == [] do
      raise "LoopQueue.topo_sort: cyclic dependency among: #{Enum.join(remaining, ", ")}"
    end

    do_topo_sort(blocked, edges, Enum.reverse(ready) ++ ordered)
  end

  defp blocked_by_remaining?(slug, edges, remaining_set) do
    Enum.any?(edges, fn {before, after_} ->
      before == slug and MapSet.member?(remaining_set, after_)
    end)
  end

  @doc """
  Classifies a single failure REASON STRING (not a file) against the same
  shared `retryable_regex` taxonomy — transport faults, 5xx, overload,
  mid-response disconnects. Used by `OrchestrationLoop` to decide whether a
  failed role call is worth more than one retry.

  Single-sources the taxonomy with `transient?/1` and with
  `harnesses/shared/retryable-errors.sh`.
  """
  @spec retryable_reason?(String.t()) :: boolean()
  def retryable_reason?(reason) when is_binary(reason),
    do: Regex.match?(@retryable_regex, reason)

  def retryable_reason?(_), do: false

  @doc """
  Classifies a single failure REASON STRING against the `switch_model_regex`
  taxonomy — the model itself is unavailable/disabled/not-found, distinct
  from a transient transport blip (`retryable_reason?/1`). Used by
  `OrchestrationLoop.do_invoke_attempt/6` to decide whether to walk the
  role's `fallback:` chain (`RoleResolver.resolve_fallback/3`) instead of
  retrying the same dead model.
  """
  @spec switch_model_reason?(String.t()) :: boolean()
  def switch_model_reason?(reason) when is_binary(reason),
    do: Regex.match?(@switch_model_regex, reason)

  def switch_model_reason?(_), do: false

  @doc """
  Classifies a captured console capture at `jsonl_path` as transient
  (retryable infra blip) vs. deterministic failure.

  Returns `true` (transient) iff:
    - the file is unreadable/missing (crashed/killed mid-flight), OR
    - a line matches the shared `retryable_regex` taxonomy (transport
      faults: socket closed, 5xx, timeouts, etc.), OR
    - no `"type":"result"` record is present (child crashed/killed
      mid-flight without ever producing a result)

  Returns `false` (deterministic failure) otherwise.
  """
  @spec transient?(String.t()) :: boolean()
  def transient?(jsonl_path) do
    case File.read(jsonl_path) do
      {:error, _reason} ->
        true

      {:ok, content} ->
        cond do
          Regex.match?(@retryable_regex, content) -> true
          not String.contains?(content, ~s("type":"result")) -> true
          true -> false
        end
    end
  end

  @doc """
  Records a pitch's retire as durable evidence, at the one moment a
  retirer holds both shas — never re-derived after the fact (see
  `codegen/pitches/shipped/a-shipped-pitch-proves-what-shipped-it.md`).

  Writes ONE thing: `shipped_sha:`/`shipped_range:` frontmatter fields
  inserted (or replaced, on a re-ship) into `pitch_path`. Answers "what
  shipped this pitch?" at the point of contact — opening the file. This
  is the ONLY record; there is no second medium to keep in sync.

  Stamped BEFORE the caller's subsequent `ready/ -> shipped/` mv,
  deliberately: `pitch_path` (a `ready/` pitch) is `@`-mentioned into
  the NEXT build's prompt (`claude-build.sh:80,93`) — an opaque
  whole-artifact read. A stamp that lands on a pitch still sitting in
  `ready/` (because the mv that follows then fails) would read as
  "already shipped" to the next planner — manufacturing the exact false
  already-done class this function exists to prevent. This window is
  narrow (a `File.rename!` immediately after `mkdir_p!` succeeds, in the
  same directory) and pre-existing; it is not enlarged by having one
  write instead of two — see
  `codegen/pitches/draft/the-ship-record-lives-only-in-the-pitch.md`
  for the removal rationale.

  Fails LOUD when git is present and the write fails: raises, naming
  `slug`, `after_sha`, and the underlying error — a retire that cannot
  be recorded must never ship silently unrecorded, which is the exact
  defect this function exists to close.

  Fails OPEN (no-op, returns `:ok`) on a non-git `cwd` / when
  `after_sha` is `nil` — mirrors `verify_commit_landed/2`'s existing
  non-git/unborn carve-out: `nil` from that function IS this carve-out,
  not a second code path that could drift from it.

  `pitch_path` is created a frontmatter block if none exists — a
  legacy-formatted pitch (no leading `---` block) is not a mis-built
  pitch; the write is additive either way.
  """
  @spec record_ship(String.t(), slug(), String.t(), String.t() | nil) :: :ok
  def record_ship(_cwd, _slug, _before_sha, nil), do: :ok

  def record_ship(cwd, slug, before_sha, after_sha) do
    case System.cmd("git", ["-C", cwd, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {_out, 0} ->
        write_frontmatter!(cwd, slug, before_sha, after_sha)
        :ok

      # not a git repo / git unavailable — fail open, mirrors
      # verify_commit_landed/2's and assert_clean_tree!/1's own posture.
      {_out, _nonzero} ->
        :ok
    end
  end

  defp write_frontmatter!(cwd, slug, before_sha, after_sha) do
    pitch_path = Path.join([cwd, "codegen", "pitches", "ready", "#{slug}.md"])

    case File.read(pitch_path) do
      {:ok, content} ->
        updated = upsert_ship_frontmatter(content, before_sha, after_sha)
        File.write!(pitch_path, updated)
        :ok

      {:error, reason} ->
        raise "LoopQueue.record_ship: failed to read #{pitch_path} to stamp ship record for " <>
                "#{slug} @ #{after_sha}: #{inspect(reason)}"
    end
  end

  @spec upsert_ship_frontmatter(String.t(), String.t(), String.t()) :: String.t()
  defp upsert_ship_frontmatter(content, before_sha, after_sha) do
    stamp_lines = [
      "shipped_sha: #{after_sha}",
      "shipped_range: #{before_sha}..#{after_sha}"
    ]

    case frontmatter_block(content) do
      nil ->
        # No well-formed frontmatter block — mint one.
        block = Enum.join(stamp_lines, "\n")
        "---\n#{block}\n---\n#{content}"

      block ->
        new_block =
          block
          |> String.split("\n")
          |> Enum.reject(
            &(String.starts_with?(String.trim(&1), "shipped_sha:") or
                String.starts_with?(String.trim(&1), "shipped_range:"))
          )
          |> Kernel.++(stamp_lines)
          |> Enum.join("\n")

        # Reconstruct via the SAME split grammar frontmatter_block/1 uses
        # (never a raw string-replace on `block`, which would be brittle
        # to incidental substring collisions) — split once on the leading
        # "---\n", then once more on the closing "\n---" boundary that
        # frontmatter_block/1 itself located.
        ["---", rest] = String.split(content, "\n", parts: 2)
        [^block, after_block] = String.split(rest, "\n---", parts: 2)
        "---\n#{new_block}\n---" <> after_block
    end
  end
end
