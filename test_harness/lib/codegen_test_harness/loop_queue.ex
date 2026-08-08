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

  @doc """
  Parses the `split_subject:` frontmatter field out of the pitch file at
  `pitch_path` — the shaper's recorded verdict that a sibling pair
  produced by a split are genuinely two bets, not one, expressed as a
  two-clause subject string (`"<clause A>; <clause B>"` or
  `"<clause A> and <clause B>"`).

  Reuses the same `extract_frontmatter_key/2` reader as `parse_scope/2`
  and `parse_edges/2` — no new frontmatter grammar.

  Returns:

    - `{:ok, nil}` — no `split_subject:` key, or no frontmatter block at
      all. The default: absent means no split is being claimed, and
      that is always a valid state.
    - `{:ok, subject}` — `split_subject:` present and contains at least
      one of the two accepted clause separators (`;` or ` and `).
    - raises — `split_subject:` present but not two-clause shaped (e.g.
      a bare scalar with neither separator). A field that LOOKS like a
      recorded verdict but names only one clause defeats the whole
      point of recording it — a loud raise naming the slug is safer
      than silently accepting it.
  """
  @spec parse_split_subject(slug(), String.t()) :: {:ok, String.t() | nil}
  def parse_split_subject(slug, pitch_path) do
    if File.exists?(pitch_path) do
      content = File.read!(pitch_path)

      case frontmatter_block(content) do
        nil ->
          {:ok, nil}

        block ->
          case extract_frontmatter_key(block, "split_subject:") do
            "" ->
              {:ok, nil}

            raw ->
              trimmed = String.trim(raw)

              if String.contains?(trimmed, ";") or String.contains?(trimmed, " and ") do
                {:ok, trimmed}
              else
                raise "LoopQueue.parse_split_subject: #{slug} has a split_subject: value " <>
                        "that is not two clauses (needs \";\" or \" and \"): #{inspect(raw)}"
              end
          end
      end
    else
      {:ok, nil}
    end
  end

  @doc """
  Parses the `commit_subject:` frontmatter field out of the pitch file at
  `pitch_path` — the shaper's sealed commit subject, written at SHAPED
  alongside `summary:`/`scope:`, and read by the loop's deterministic
  commit step (`codegen-commit`) in place of a paid committer-role guess.

  Reuses the same `extract_frontmatter_key/2` reader as `parse_scope/2`,
  `parse_split_subject/2`, and `parse_edges/2` — a scalar key, no new
  frontmatter grammar. Mechanical validity (length, single-line, casing,
  trailing punctuation, trailer tokens) is NOT checked here — that lives
  in `codegen-commit --check-subject`, the single implementation shared
  by `/ready`, `pitch-format-validator.sh`, and this pre-claim check, so
  the rule is defined once.

  Returns:

    - `{:ok, nil}` — no `commit_subject:` key, or no frontmatter block at
      all. A literal-prompt build or a pitch in a repo with no shape
      workflow carries no frontmatter at all — this is always a legal
      absence, resolved at the `--commit-subject` CLI-flag call site
      instead (see `Mix.Tasks.Codegen.Loop`).
    - `{:ok, subject}` — `commit_subject:` present, trimmed.
  """
  @spec parse_commit_subject(slug(), String.t()) :: {:ok, String.t() | nil}
  def parse_commit_subject(_slug, pitch_path) do
    if File.exists?(pitch_path) do
      content = File.read!(pitch_path)

      case frontmatter_block(content) do
        nil ->
          {:ok, nil}

        block ->
          case extract_frontmatter_key(block, "commit_subject:") do
            "" -> {:ok, nil}
            raw -> {:ok, String.trim(raw)}
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

  @type handoff_record :: %{
          delta_id: String.t(),
          source: slug(),
          owner: slug(),
          path: String.t()
        }

  @handoff_record_regex ~r/^([a-z0-9][a-z0-9-]*)::([a-z0-9][a-z0-9-]*)::([a-z0-9][a-z0-9-]*)::(.+)$/

  @doc """
  Parses the `handoffs:` frontmatter field out of the pitch file at
  `pitch_path` — a flow-list of bilateral cross-pitch deferral records,
  each shaped `<delta-id>::<source-slug>::<owner-slug>::<repo-relative-
  path>` (see `codegen/pitches/draft/deferred-work-has-exactly-one-owner.md`).

  Reuses the SAME frontmatter spine as `parse_scope/2`
  (`frontmatter_block/1` -> `extract_frontmatter_key/2` ->
  `parse_flow_list_strict/1`) — no new frontmatter grammar, only a new
  per-item record grammar layered on top of the existing flow-list
  parser.

  Returns:

    - `{:ok, nil}` — no `handoffs:` key, or no frontmatter block at all
    - `{:ok, [%{delta_id:, source:, owner:, path:}, ...]}` — well-formed
      flow-list, each item matching the record grammar (possibly `[]`)
    - raises — `handoffs:` present but not a parseable `[...]` flow-list,
      OR a well-formed flow-list containing at least one item that does
      not match the record grammar (wrong token shape, `source ==
      owner`, or a path containing `..`, a leading/trailing slash, a
      backslash, an ASCII control character, a comma, a square bracket,
      or the reserved `::` delimiter). A confidently-wrong partial
      parse is worse than a loud crash naming the slug and the bad
      token.
  """
  @spec parse_handoffs(slug(), String.t()) :: {:ok, [handoff_record()] | nil}
  def parse_handoffs(slug, pitch_path) do
    if File.exists?(pitch_path) do
      content = File.read!(pitch_path)

      case frontmatter_block(content) do
        nil ->
          {:ok, nil}

        block ->
          case extract_frontmatter_key(block, "handoffs:") do
            "" ->
              {:ok, nil}

            raw ->
              case parse_flow_list_strict(raw) do
                {:ok, tokens} ->
                  {:ok, Enum.map(tokens, &parse_handoff_token!(slug, &1))}

                :error ->
                  raise "LoopQueue.parse_handoffs: #{slug} has a handoffs: value that is " <>
                          "not a parseable [...] flow-list: #{inspect(raw)}"
              end
          end
      end
    else
      {:ok, nil}
    end
  end

  @spec parse_handoff_token!(slug(), String.t()) :: handoff_record()
  defp parse_handoff_token!(slug, token) do
    case Regex.run(@handoff_record_regex, token) do
      [_, delta_id, source, owner, path] ->
        cond do
          source == owner ->
            raise "LoopQueue.parse_handoffs: #{slug} has a handoffs: record with " <>
                    "source == owner (#{inspect(source)}): #{inspect(token)}"

          not valid_handoff_path?(path) ->
            raise "LoopQueue.parse_handoffs: #{slug} has a handoffs: record with an " <>
                    "invalid path: #{inspect(token)}"

          true ->
            %{delta_id: delta_id, source: source, owner: owner, path: path}
        end

      nil ->
        raise "LoopQueue.parse_handoffs: #{slug} has a handoffs: record that does not " <>
                "match <delta-id>::<source-slug>::<owner-slug>::<path>: #{inspect(token)}"
    end
  end

  # path must be `/`-separated non-empty segments, no leading/trailing
  # slash, no "." or ".." segment, no backslash, no ASCII control byte, no
  # comma, no square bracket, no reserved "::" delimiter.
  @spec valid_handoff_path?(String.t()) :: boolean()
  defp valid_handoff_path?(path) do
    path != "" and
      not String.starts_with?(path, "/") and
      not String.ends_with?(path, "/") and
      not String.contains?(path, "\\") and
      not String.contains?(path, "::") and
      not String.contains?(path, ",") and
      not String.contains?(path, "[") and
      not String.contains?(path, "]") and
      not Regex.match?(~r/[\x00-\x1f]/, path) and
      path
      |> String.split("/")
      |> Enum.all?(fn segment -> segment != "" and segment != "." and segment != ".." end)
  end

  @doc """
  Computes the portable `handoff_receipt:` digest for `slug`'s
  `handoffs:` `records` — `"sha256:" <> 64 lowercase hex` over
  `slug <> "\\n" <> Enum.join(bytewise_sorted_canonical_records, "\\n")
  <> "\\n"`, UTF-8 bytes.

  Sorting the canonical record strings before hashing means the digest
  is independent of the AUTHOR'S ORDER in the flow-list — two pitches
  whose records are byte-identical but were typed in a different order
  still produce the same receipt. Canonical record form is the same
  `<delta-id>::<source>::<owner>::<path>` token grammar `parse_handoffs/2`
  reads back.
  """
  @spec handoff_receipt(slug(), [handoff_record()]) :: String.t()
  def handoff_receipt(slug, records) do
    canonical =
      records
      |> Enum.map(&canonical_handoff_token/1)
      |> Enum.sort()

    payload = slug <> "\n" <> Enum.join(canonical, "\n") <> "\n"
    digest = :crypto.hash(:sha256, payload)
    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  @spec canonical_handoff_token(handoff_record()) :: String.t()
  defp canonical_handoff_token(%{delta_id: d, source: s, owner: o, path: p}) do
    "#{d}::#{s}::#{o}::#{p}"
  end

  @handoff_receipt_regex ~r/^sha256:[0-9a-f]{64}$/

  @doc """
  Reconciles a `slug`'s parsed `handoffs:` `records` against the
  corresponding participant pitch files found under `pitches_dirs` (a
  list of directories to search, e.g. `draft/`, `ready/`, `shipped/` —
  see `codegen/pitches/draft/deferred-work-has-exactly-one-owner.md`).

  For every record `{delta_id, source, owner, path}` naming `slug` as
  EITHER `source` or `owner`, the counterpart participant must exist
  under one of `pitches_dirs`, carry an IDENTICAL copy of the record in
  its own `handoffs:` list, and (when `slug` is the `source`) the
  `owner` pitch's `scope:` must contain `path`. One `delta_id` may
  recur with different `path`s only when `source`/`owner` stay
  identical across every recurrence — reusing a `delta_id` with a
  different source or owner is a conflict.

  Returns `:ok` when every record for `slug` reconciles cleanly (`slug`
  may also have zero `handoffs:` — an empty pass), or
  `{:error, reason}` naming the first problem found — never a partial
  or best-effort pass. Uses a visited-set walk (`visited` param,
  default `MapSet.new()`) so a graph cycle among counterpart pitches
  terminates rather than looping.
  """
  @spec reconcile_handoffs(slug(), String.t(), [String.t()], MapSet.t()) ::
          :ok | {:error, String.t()}
  def reconcile_handoffs(slug, pitch_path, pitches_dirs, visited \\ MapSet.new()) do
    if MapSet.member?(visited, slug) do
      :ok
    else
      visited = MapSet.put(visited, slug)

      with {:ok, records} <- parse_handoffs(slug, pitch_path) do
        (records || [])
        |> Enum.reduce_while(:ok, fn record, :ok ->
          case reconcile_one_handoff(slug, record, pitches_dirs, visited) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
        end)
      end
    end
  end

  @spec reconcile_one_handoff(slug(), handoff_record(), [String.t()], MapSet.t()) ::
          :ok | {:error, String.t()}
  defp reconcile_one_handoff(slug, record, pitches_dirs, visited) do
    counterpart_slug = if slug == record.source, do: record.owner, else: record.source

    case find_pitch_file(counterpart_slug, pitches_dirs) do
      nil ->
        {:error,
         "HANDOFF GAP #{record.delta_id}: participant #{inspect(counterpart_slug)} " <>
           "(referenced by #{inspect(slug)}) not found under #{inspect(pitches_dirs)}"}

      counterpart_path ->
        with {:ok, counterpart_records} <- parse_handoffs(counterpart_slug, counterpart_path) do
          if record in (counterpart_records || []) do
            with :ok <- check_owner_scope(record, pitches_dirs) do
              reconcile_handoffs(counterpart_slug, counterpart_path, pitches_dirs, visited)
            end
          else
            {:error,
             "HANDOFF GAP #{record.delta_id}: #{inspect(slug)} and " <>
               "#{inspect(counterpart_slug)} do not carry an identical copy of the record"}
          end
        end
    end
  end

  @spec check_owner_scope(handoff_record(), [String.t()]) :: :ok | {:error, String.t()}
  defp check_owner_scope(%{owner: owner, path: path, delta_id: delta_id}, pitches_dirs) do
    case find_pitch_file(owner, pitches_dirs) do
      nil ->
        {:error, "HANDOFF GAP #{delta_id}: owner #{inspect(owner)} not found"}

      owner_path ->
        case parse_scope(owner, owner_path) do
          {:ok, owner_scope} when is_list(owner_scope) ->
            if path in owner_scope do
              :ok
            else
              {:error,
               "HANDOFF GAP #{delta_id}: owner #{inspect(owner)} does not list " <>
                 "#{inspect(path)} in its scope:"}
            end

          {:ok, nil} ->
            {:error, "HANDOFF GAP #{delta_id}: owner #{inspect(owner)} has no scope: field"}
        end
    end
  end

  @spec find_pitch_file(slug(), [String.t()]) :: String.t() | nil
  defp find_pitch_file(slug, pitches_dirs) do
    Enum.find_value(pitches_dirs, fn dir ->
      candidate = Path.join(dir, "#{slug}.md")
      if File.exists?(candidate), do: candidate
    end)
  end

  @doc """
  Upserts `handoff_receipt: <receipt>` into the pitch file at
  `draft_path`'s frontmatter block, via the SAME reconstruction grammar
  `upsert_frontmatter_lines/2` already uses for `build_failures:` and
  `demoted_from:` — no second frontmatter grammar.

  Compare-and-swap: `expected_content` must equal the CURRENT bytes on
  disk at `draft_path` at write time, or the write is refused with
  `{:error, :stale}` and NOTHING is written — a source that changed
  between the caller's precompute step and this call must never have
  its update silently applied on top of newer, unseen bytes. Callers
  precompute `expected_content` (the exact bytes they read and derived
  `receipt` from), write via a same-directory temp file, then rename
  atomically over `draft_path` only after re-reading and confirming
  `draft_path` still holds `expected_content`.

  Returns `:ok` on a successful atomic write, `{:error, :stale}` on a
  detected race, or raises on a read failure (mirrors
  `write_build_failures!/3` — the file disappearing between the
  caller's existence check and this call is a genuine anomaly, not a
  documented sentinel).
  """
  @spec write_handoff_receipt!(String.t(), String.t(), String.t()) :: :ok | {:error, :stale}
  def write_handoff_receipt!(draft_path, expected_content, receipt) do
    unless Regex.match?(@handoff_receipt_regex, receipt) do
      raise "LoopQueue.write_handoff_receipt!: #{inspect(receipt)} is not a well-formed " <>
              "sha256:<64 lowercase hex> receipt"
    end

    case File.read(draft_path) do
      {:ok, ^expected_content} ->
        updated = upsert_frontmatter_lines(expected_content, ["handoff_receipt: #{receipt}"])
        tmp_path = "#{draft_path}.#{:erlang.unique_integer([:positive])}"
        File.write!(tmp_path, updated)

        case File.read(draft_path) do
          {:ok, ^expected_content} ->
            File.rename!(tmp_path, draft_path)
            :ok

          _ ->
            File.rm(tmp_path)
            {:error, :stale}
        end

      {:ok, _other} ->
        {:error, :stale}

      {:error, reason} ->
        raise "LoopQueue.write_handoff_receipt!: failed to read #{draft_path}: #{inspect(reason)}"
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

  @doc """
  Scans the `.md` slugs under `pitches_dir` and returns the list of
  `{subsumed_slug, superset_slug}` pairs where `subsumed_slug`'s
  `scope:` is a subset of (or equal to) `superset_slug`'s `scope:`, and
  NEITHER pitch declares `split_subject:` — the mechanical shadow of
  "this split was never proven to be two bets" (see
  `codegen/pitches/ready/a-split-pitch-must-be-two-real-bets.md`).

  A pitch with `scope: []` (present, explicitly empty) is EXCLUDED from
  this check entirely — `[] ⊆ X` is vacuously true for every scoped X,
  so including empty-scope pitches would flag every one of them against
  every other scoped pitch in the batch. Unrouted pitches (no `scope:`
  key at all) are excluded too; that is `scope_report/1`'s concern.

  When two pitches have IDENTICAL non-empty scope sets, that is still
  reported — subsumption in both directions collapses to a single pair
  (lexicographically-lower slug first), never emitted twice.

  Either sibling declaring `split_subject:` clears the pair — the
  escape hatch is "prove it is two bets", not "only the smaller one may
  speak up".

  Pure/deterministic — no LLM, no network.
  """
  @spec subsumed_report(String.t()) :: [{slug(), slug()}]
  def subsumed_report(pitches_dir) do
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
          {:ok, []} -> acc
          {:ok, paths} -> Map.put(acc, slug, MapSet.new(paths))
        end
      end)

    scoped_slugs = scoped |> Map.keys() |> Enum.sort()

    split_subjects =
      Enum.reduce(scoped_slugs, %{}, fn slug, acc ->
        case parse_split_subject(slug, Path.join(pitches_dir, "#{slug}.md")) do
          {:ok, nil} -> acc
          {:ok, subject} -> Map.put(acc, slug, subject)
        end
      end)

    for {slug_a, i} <- Enum.with_index(scoped_slugs),
        slug_b <- Enum.drop(scoped_slugs, i + 1),
        not Map.has_key?(split_subjects, slug_a),
        not Map.has_key?(split_subjects, slug_b),
        pair = subsumed_pair(slug_a, scoped[slug_a], slug_b, scoped[slug_b]),
        pair != nil do
      pair
    end
  end

  # Determines subsumption direction between two scope sets, returning
  # {subsumed_slug, superset_slug} (subsumed listed first) or nil when
  # neither is a subset of the other. Equal sets report {a, b} in the
  # slugs' sorted order (a < b, guaranteed by subsumed_report/1's
  # Enum.with_index/Enum.drop pairing), never emitted twice.
  @spec subsumed_pair(slug(), MapSet.t(), slug(), MapSet.t()) :: {slug(), slug()} | nil
  defp subsumed_pair(slug_a, set_a, slug_b, set_b) do
    cond do
      MapSet.equal?(set_a, set_b) -> {slug_a, slug_b}
      MapSet.subset?(set_a, set_b) -> {slug_a, slug_b}
      MapSet.subset?(set_b, set_a) -> {slug_b, slug_a}
      true -> nil
    end
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

  @doc """
  Fleet-safe sibling of `partition/2`. Identical scope-collision +
  `blocks_on:` union-find graph construction, EXCEPT a component is
  DEPENDENCY-BOUND — held back from every lane, returned separately as
  `dependency_bound` — when it contains any pitch that is:

    - the SOURCE of a `blocks_on:` edge, INCLUDING an edge whose
      dependency is absent from this batch (a "dead" edge to
      `partition/2`, which silently ignores it — here it is the
      opposite: the crux inversion this function exists for. A
      dependency pointing outside the batch may point at a pitch that
      already shipped on a DIFFERENT fleet node; moving this pitch away
      from its prerequisite's node would split the chain), or
    - named in `externally_referenced` — slugs some fleet-ready pitch,
      on ANY node (including this one), lists as ITS `blocks_on:`
      dependency (i.e. this component is a prerequisite some other
      ready pitch needs local), or
    - a `scope:` collision peer of either of the above (moving that
      peer alone would let two dependency-bound halves of one
      collision component land on different nodes, re-introducing the
      exact cross-node edit collision `partition/2`'s co-location
      already prevents).

  Only components with ZERO fleet dependency edges (in either
  direction) are lane-eligible; their scope-size balancing across lanes
  is otherwise identical to `partition/2`.

  Returns `{lanes, global_hot, unrouted, dependency_bound}` — the first
  three fields mean exactly what they mean in `partition/2`, computed
  over the SAME scoped/global_hot/unrouted classification;
  `dependency_bound` is the new fourth field, sorted slugs list (`[]`
  when none).

  Raises when `lane_count` is not a positive integer (same contract as
  `partition/2`).
  """
  @spec fleet_partition(String.t(), pos_integer(), MapSet.t(slug())) ::
          {lanes :: [[slug()]], global_hot :: [slug()], unrouted :: [slug()],
           dependency_bound :: [slug()]}
  def fleet_partition(pitches_dir, lane_count, externally_referenced)
      when is_integer(lane_count) and lane_count > 0 do
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

    global_hot =
      scoped_slugs
      |> Enum.filter(&collides_with_every_other_slug?(&1, scoped_slugs, scoped))
      |> Enum.sort()

    placeable_slugs = scoped_slugs -- global_hot

    # Fleet-bound seeds: outgoing edge sources (even to an absent/external
    # dep) OR named as an external dependency by anything on the fleet.
    fleet_bound_seeds =
      placeable_slugs
      |> Enum.filter(fn slug ->
        has_outgoing_edge? = Enum.any?(blocks_edges, fn {s, _dep} -> s == slug end)
        externally_referenced? = MapSet.member?(externally_referenced, slug)
        has_outgoing_edge? or externally_referenced?
      end)
      |> MapSet.new()

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

    {bound_components, free_components} =
      Enum.split_with(components, fn comp ->
        Enum.any?(comp, &MapSet.member?(fleet_bound_seeds, &1))
      end)

    dependency_bound = bound_components |> List.flatten() |> Enum.sort()

    lanes =
      free_components
      |> Enum.sort_by(fn comp -> -component_scope_size(comp, scoped) end)
      |> assign_components_to_lanes(lane_count, scoped)
      |> Enum.map(fn lane_slugs ->
        lane_edges =
          Enum.filter(placeable_blocks_edges, fn {s, dep} ->
            s in lane_slugs and dep in lane_slugs
          end)

        topo_sort(Enum.sort(lane_slugs), lane_edges)
      end)

    {lanes, global_hot, unrouted, dependency_bound}
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
  Returns every `.md` slug under `ready_dir` whose `blocks_on:` edges name
  `dep_slug` (i.e. every pitch that would be stranded as an unmet-dep skip
  if `dep_slug` were removed from `ready_dir` right now). Used by
  `LoopQueueDrain`'s auto-demotion path to name the cascade a demotion just
  caused, alongside the count already reported by `blocked_by_unmet_dep/3`.

  Sorted for deterministic output. `[]` when `dep_slug` has no dependents
  in `ready_dir`, or `ready_dir` does not exist.
  """
  @spec dependents_of(String.t(), slug()) :: [slug()]
  def dependents_of(ready_dir, dep_slug) do
    ready_dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".md"))
    |> Enum.reject(&(&1 == dep_slug))
    |> Enum.filter(fn slug ->
      slug
      |> parse_edges(Path.join(ready_dir, "#{slug}.md"))
      |> Enum.any?(fn {_slug, dep} -> dep == dep_slug end)
    end)
    |> Enum.sort()
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
  the NEXT build's prompt (`claude-build.sh`'s basename-resolver
  `@`-mention lines) — an opaque whole-artifact read. A stamp that lands
  on a pitch still sitting in
  `ready/` (because the mv that follows then fails) would read as
  "already shipped" to the next build — manufacturing the exact false
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
    ready_path = Path.join([cwd, "codegen", "pitches", "ready", "#{slug}.md"])
    building_path = Path.join([cwd, "codegen", "pitches", "building", "#{slug}.md"])
    shipped_path = Path.join([cwd, "codegen", "pitches", "shipped", "#{slug}.md"])

    # A re-stamp (e.g. the queue drain's post-rebase re-stamp of an already
    # published sha) targets a pitch that has ALREADY been moved out of
    # ready/ — try ready/ first (the normal, pre-claim ship path), then
    # building/ (a claimed pitch mid-cycle — the normal ship path under
    # possession-by-rename), then fall back to shipped/ before raising.
    # None of the three existing is the genuine anomaly this raise exists
    # to catch.
    pitch_path =
      cond do
        File.exists?(ready_path) -> ready_path
        File.exists?(building_path) -> building_path
        true -> shipped_path
      end

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

  @doc """
  Reads the `build_failures:` frontmatter counter from the pitch file at
  `pitch_path`, returning 0 when the key, the frontmatter block, or the
  file itself is absent — or when the value is not a bare non-negative
  integer. This is the documented "no failures recorded yet" sentinel, not
  an error: a pitch's very first deterministic failure legitimately has no
  prior counter to read.
  """
  @spec parse_build_failures(slug(), String.t()) :: non_neg_integer()
  def parse_build_failures(_slug, pitch_path) do
    if File.exists?(pitch_path) do
      content = File.read!(pitch_path)

      case frontmatter_block(content) do
        nil ->
          0

        block ->
          case extract_frontmatter_key(block, "build_failures:") do
            "" ->
              0

            raw ->
              case Integer.parse(String.trim(raw)) do
                {n, ""} when n >= 0 -> n
                _ -> 0
              end
          end
      end
    else
      0
    end
  end

  @doc """
  Upserts `build_failures: <count>` into `pitch_path`'s frontmatter block
  (minting one if absent, via the same reconstruction grammar
  `upsert_ship_frontmatter/3` uses) AND appends `history_row` under the
  `## Build failure history` section (minting the section the first time) —
  ONE file rewrite covering both the counter and the durable evidence row.
  Every counted deterministic failure gets a row from failure #1 onward,
  not only at demotion (`write_demotion!/5` appends the row for the
  THRESHOLD failure that also moves the pitch to `draft/`).

  Raises on a read failure (mirrors `write_frontmatter!/4` — the pitch file
  disappearing between the caller's existence check and this write is a
  genuine anomaly, not a documented sentinel).
  """
  @spec write_build_failures!(String.t(), non_neg_integer(), String.t()) :: :ok
  def write_build_failures!(pitch_path, count, history_row) do
    case File.read(pitch_path) do
      {:ok, content} ->
        updated =
          content
          |> upsert_frontmatter_lines(["build_failures: #{count}"])
          |> append_history_row("Build failure history", history_row)

        File.write!(pitch_path, updated)
        :ok

      {:error, reason} ->
        raise "LoopQueue.write_build_failures!: failed to read #{pitch_path}: #{inspect(reason)}"
    end
  end

  @doc false
  @spec write_history_row!(String.t(), String.t(), String.t()) :: :ok
  def write_history_row!(pitch_path, header, row) do
    content = File.read!(pitch_path)
    File.write!(pitch_path, append_history_row(content, header, row))
    :ok
  end

  @doc """
  Demotes the pitch at `pitch_path` (currently `ready/<slug>.md` or a
  `building/<slug>.md` stranded-by-crash shape) to `draft_path` —
  `ready/`/`building/ -> draft/`, the mirror image of `record_ship/4`'s
  `ready|building -> shipped` direction, for the FAILURE side of the
  lifecycle. Byte-for-byte the hand-written template in
  `codegen/pitches/shipped/the-guard-parses-quotes-worse-than-the-shell-it-guards.md`
  (frontmatter: `build_failures:`, `demoted_from: ready`, `demote_reason:
  deterministic-build-failure-x<N>`, `status: SHAPING`; body: an appended
  `## Build failure history` section, one row per demoting run).

  `history_row` is a single already-formatted markdown table row (`| ... |
  ... |`) for THIS run — the caller assembles it (run label, cost, terminal
  reason) since only the caller knows those. Rows accumulate from the
  pitch's FIRST counted deterministic failure onward (see
  `write_build_failures!/3`) — demotion is simply the threshold failure's
  row landing in the same section right before the `ready/ -> draft/` move.
  A pitch demoted more than once in its lifetime (re-queued after
  reshaping, fails again) accumulates one row per demotion; this function
  never truncates or replaces prior rows.

  Raises on a read failure (mirrors `write_frontmatter!/4`) or on a
  `File.rename!/2` failure (mirrors `record_ship/4`'s `ship/6`
  counterpart) — a demotion that can't actually move the file must not be
  reported as having happened.
  """
  @spec write_demotion!(String.t(), String.t(), non_neg_integer(), String.t(), String.t()) :: :ok
  def write_demotion!(pitch_path, draft_path, count, history_row, header) do
    case File.read(pitch_path) do
      {:ok, content} ->
        updated =
          content
          |> upsert_frontmatter_lines([
            "build_failures: #{count}",
            "demoted_from: ready",
            "demote_reason: deterministic-build-failure-x#{count}",
            "status: SHAPING"
          ])
          |> append_history_row(header, history_row)

        File.write!(pitch_path, updated)
        File.mkdir_p!(Path.dirname(draft_path))
        File.rename!(pitch_path, draft_path)
        :ok

      {:error, reason} ->
        raise "LoopQueue.write_demotion!: failed to read #{pitch_path}: #{inspect(reason)}"
    end
  end

  @default_max_pitch_fails 2

  @doc """
  Resolves `CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS`, default
  #{@default_max_pitch_fails}. The SOLE definition — `LoopQueueDrain` reads
  the env var only through this function (never re-parses it) so a
  context-free counted write (`record_counted_history!/3`, called from
  `InterruptedCycleRecovery` where no drain `state` map exists yet) and a
  drain-state counted write agree on the exact same threshold with no
  circular module dependency (`LoopQueueDrain` already depends on
  `InterruptedCycleRecovery`, so the reverse dependency is forbidden).
  """
  @spec max_pitch_fails_from_env() :: pos_integer()
  def max_pitch_fails_from_env do
    case System.get_env("CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS") do
      nil ->
        @default_max_pitch_fails

      str ->
        case Integer.parse(str) do
          {n, ""} when n > 0 -> n
          _ -> @default_max_pitch_fails
        end
    end
  end

  @doc """
  Context-free counted write for a recovery-shaped `## Build failure
  history` row — reads `build_failures:`, increments it, and either
  appends the row (below threshold) or demotes the pitch to
  `draft_dir/<slug>.md` (at `max_pitch_fails_from_env/0`'s threshold),
  exactly like `LoopQueueDrain.record_build_failure/4`'s deterministic
  path, but callable BEFORE a drain `state` map exists (`reconcile/1` runs
  during `LoopQueueDrain.drain/1`'s own startup `with` chain, ahead of the
  `state = %{...}` literal — see `InterruptedCycleRecovery`'s moduledoc
  note above `write_history!/3`).

  `pitch_path` is the claim's CURRENT physical location (the caller
  resolves it — this function does not probe `ready_dir`/`building_dir`
  itself, since `InterruptedCycleRecovery`'s callers already know exactly
  which file the claim was restored to). `draft_dir` is the absolute path
  to `codegen/pitches/draft` the demoted file lands in. `row` is the
  already-formatted markdown table row for this attempt.

  Returns the resolved `count` on success (fail-open by design: a caller
  whose OWN row-write already has a non-blocking-observability posture,
  e.g. `InterruptedCycleRecovery.write_history!/3`, can rescue this and log
  rather than propagate — mirroring `record_build_failure/4`'s own
  fail-CLOSED semantics would turn a startup recovery notice into a drain
  HALT, which is a stronger posture than a recovery-of-an-already-terminal
  attempt warrants). Raises on the same conditions `write_build_failures!/3`
  and `write_demotion!/5` already raise on (a read/write/rename failure
  against a pitch file proven present moments earlier) — callers that need
  non-blocking behavior wrap this in their own rescue, exactly as they do
  today for `write_history_row!/3`.
  """
  @spec record_counted_history!(String.t(), String.t(), String.t()) :: non_neg_integer()
  def record_counted_history!(pitch_path, draft_dir, row) do
    slug = Path.basename(pitch_path, ".md")
    count = parse_build_failures(slug, pitch_path) + 1

    if count >= max_pitch_fails_from_env() do
      draft_path = Path.join(draft_dir, "#{slug}.md")
      write_demotion!(pitch_path, draft_path, count, row, "Build failure history")
    else
      write_build_failures!(pitch_path, count, row)
    end

    count
  end

  # Shared frontmatter upsert grammar — reused by write_build_failures!/2 and
  # write_demotion!/5 so the increment-only write and the full-demotion write
  # can never disagree on how `key: value` lines are inserted or replaced.
  # `new_lines` entries are `"key: value"` strings; a line already present
  # (matched by its `key:` prefix) is replaced in place, else appended.
  @spec upsert_frontmatter_lines(String.t(), [String.t()]) :: String.t()
  defp upsert_frontmatter_lines(content, new_lines) do
    keys = Enum.map(new_lines, &(&1 |> String.split(":", parts: 2) |> hd() |> Kernel.<>(":")))

    case frontmatter_block(content) do
      nil ->
        block = Enum.join(new_lines, "\n")
        "---\n#{block}\n---\n#{content}"

      block ->
        new_block =
          block
          |> String.split("\n")
          |> Enum.reject(fn line ->
            trimmed = String.trim(line)
            Enum.any?(keys, &String.starts_with?(trimmed, &1))
          end)
          |> Kernel.++(new_lines)
          |> Enum.join("\n")

        # Reconstruct via the SAME split grammar frontmatter_block/1 uses —
        # see upsert_ship_frontmatter/3's identical comment.
        ["---", rest] = String.split(content, "\n", parts: 2)
        [^block, after_block] = String.split(rest, "\n---", parts: 2)
        "---\n#{new_block}\n---" <> after_block
    end
  end

  # Mints a `## <header>` section (first failure) or inserts one more table
  # row INSIDE the EXISTING section (subsequent failures) in the pitch BODY
  # (after the frontmatter block). Insertion lands after the section's last
  # existing table row and BEFORE the next `## ` heading — EOF only when no
  # `## ` heading follows the history section. A blind EOF-append (the prior
  # behavior) put later rows AFTER unrelated sections such as `## Problem`,
  # breaking the table it claimed to extend. Normalizes a missing trailing
  # newline before appending so a minted section never runs onto the same
  # line as the file's last byte.
  #
  # The marker is located ONLY where it begins a line (start-of-string, or
  # immediately after a newline) — a bare `String.contains?`/`String.split`
  # on the marker text matches ANY substring occurrence, including a prose
  # mention of the heading inside an unrelated section, or a mention inside a
  # backtick code span. A pitch body that discusses its own `## Build failure
  # history` section in prose (as this repo's own pitches legitimately do)
  # would otherwise have every row spliced in at that first prose mention
  # instead of the real heading — reproduced and confirmed against a real
  # pitch body before this fix.
  @spec append_history_row(String.t(), String.t(), String.t()) :: String.t()
  defp append_history_row(content, header, row) do
    normalized = String.trim_trailing(content) <> "\n"
    marker = "## #{header}"
    # Line-start anchor: `\A` (string start) or a literal `\n` immediately
    # before the marker, with a mandatory trailing `\n` — so the marker only
    # counts when it is the ENTIRE content of a line. `Regex.run/3` with
    # `return: :index` gives the BYTE range of the WHOLE match (group 0,
    # first tuple) — used to slice `before`/`after_marker` around exactly
    # the matched marker text, never the surrounding `\A|\n` anchor bytes.
    #
    # Those offsets are BYTES, so the slices must be taken in bytes too.
    # `String.slice/2,3` counts GRAPHEMES, and a pitch body is full of
    # multi-byte characters (em dashes, arrows, ✅) — every one of them
    # drifts the two scales further apart, so the grapheme-indexed slice cut
    # the prefix short and the section splice landed mid-sentence, silently
    # DESTROYING everything between the two positions. Measured on
    # `rules-grants-and-guards-match-reality.md`: 102_927 bytes of prefix but
    # 102_229 graphemes — a 698-character hole punched through the durable
    # recovery evidence (the parked WIP's own recovery ref, commit and tree
    # sha) the row was being appended to record.
    anchored_marker = Regex.compile!("(?:\\A|\\n)(#{Regex.escape(marker)})\\n")

    case Regex.run(anchored_marker, normalized, return: :index) do
      [_whole, {marker_start, marker_len}] ->
        marker_end = marker_start + marker_len
        before = binary_part(normalized, 0, marker_start)
        after_marker = binary_part(normalized, marker_end, byte_size(normalized) - marker_end)

        case String.split(after_marker, "\n## ", parts: 2) do
          [section_only] ->
            # History section is the LAST section in the file — EOF append.
            before <> marker <> String.trim_trailing(section_only) <> "\n" <> row <> "\n"

          [section, rest] ->
            # Another `## ` heading follows — insert before it, inside the
            # history section.
            before <>
              marker <> String.trim_trailing(section) <> "\n" <> row <> "\n\n## " <> rest
        end

      nil ->
        normalized <>
          "\n" <>
          marker <>
          "\n\n" <>
          "| run | when | cost | terminal reason |\n" <>
          "|---|---|---|---|\n" <>
          row <> "\n"
    end
  end

  @failure_summary_limit 500

  @doc """
  Escapes `cell` for safe embedding as ONE markdown table cell: replaces
  CR/LF with a single space (a raw newline inside a `| ... |` row would
  split it across lines and corrupt the table), escapes a literal `|` as
  `\\|` (an unescaped pipe would be read as a column boundary), and trims
  surrounding whitespace. Called by `LoopQueueDrain` when assembling a
  `## Build failure history` row from free-form terminal reasons / model
  prose — this module owns pitch-file grammar, so the escaping rule lives
  here rather than being duplicated at the call site.
  """
  @spec escape_history_cell(String.t()) :: String.t()
  def escape_history_cell(cell) do
    cell
    |> String.replace(["\r\n", "\r", "\n"], " ")
    |> String.replace("|", "\\|")
    |> String.trim()
  end

  @doc """
  Truncates `text` to at most 500 Unicode codepoints, appending
  `… [truncated; raw=<raw_path>]` when truncation actually occurred — so an
  unbounded model-produced summary can never grow a pitch file without
  bound, while still naming where the FULL evidence remains on disk.
  Returns `text` unchanged when it already fits.
  """
  @spec truncate_summary(String.t(), String.t()) :: String.t()
  def truncate_summary(text, raw_path) do
    if String.length(text) > @failure_summary_limit do
      String.slice(text, 0, @failure_summary_limit) <> "… [truncated; raw=#{raw_path}]"
    else
      text
    end
  end
end
