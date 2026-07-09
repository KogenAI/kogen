defmodule CodegenTestHarness.LoopQueue do
  @moduledoc """
  Absorbs `harnesses/shared/build-queue.sh`'s pure-logic pieces: scans
  `codegen/pitches/ready/` pitch files, topologically sorts their
  `Blocks-on:`/`## Dependencies` edges (Kahn's algorithm, deps first),
  and classifies a captured console capture as a transient (retryable)
  infra blip via `retryable_regex` (ported from
  `harnesses/shared/retryable-errors.sh`).

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
  Parses `Blocks-on:` lines and `## Dependencies` bullet lists out of the
  pitch file at `pitch_path`, returning `{slug, dep}` edge tuples (`slug`
  depends on/is blocked by `dep`).

  Returns `[]` if `pitch_path` does not exist (mirrors the shell's silent
  no-op via `2>/dev/null || true`).
  """
  @spec parse_edges(slug(), String.t()) :: [edge()]
  def parse_edges(slug, pitch_path) do
    if File.exists?(pitch_path) do
      pitch_path
      |> File.read!()
      |> String.split("\n")
      |> parse_edge_lines(slug, false)
    else
      []
    end
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
