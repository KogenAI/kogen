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
  """
  @spec ordered_slugs(String.t()) :: [slug()]
  def ordered_slugs(ready_dir) do
    slugs =
      ready_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".md"))
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

  # Returns the raw text between the opening and closing `---` delimiters
  # when `content` starts with a frontmatter block, else nil. The opening
  # delimiter MUST be the very first line (no leading blank lines).
  @spec frontmatter_block(String.t()) :: String.t() | nil
  defp frontmatter_block(content) do
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

  # Reads a `blocks_on: [a, b]` inline flow-list from a frontmatter block
  # body. Absent key, or `blocks_on: []`, returns [].
  @spec parse_frontmatter_blocks_on(String.t()) :: [slug()]
  defp parse_frontmatter_blocks_on(block) do
    block
    |> String.split("\n")
    |> Enum.find_value("", &frontmatter_blocks_on_line/1)
    |> parse_flow_list()
  end

  defp frontmatter_blocks_on_line(line) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "blocks_on:") do
      String.trim_leading(trimmed, "blocks_on:")
    end
  end

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
  """
  @spec blocked_by_unmet_dep(String.t(), String.t()) :: blocked_map()
  def blocked_by_unmet_dep(ready_dir, shipped_dir) do
    ready_slugs =
      ready_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".md"))

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
end
