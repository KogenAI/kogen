defmodule Kogen.Build.FailureSignature do
  @moduledoc """
  Bounded descriptive fingerprints derived only from settled receipts.

  The controller derives every signature generically: it knows no target
  name, runner or test framework. A target may print one optional,
  documented frame (README, `scripts/check/README.md`):

      KOGEN_FAILURE_SIGNATURE\t{"stage":…,"test_id":…,"assertion":…}

  When present, the digest is the target plus those fields, and they also
  give `primary_lines/2`'s excerpt for the resume prompt. Without it, the
  signature falls back to the normalized failure tail: the last failure
  lines (not the first 320 characters of the whole receipt), with ANSI
  codes, seeds, durations, timestamps, temporary paths, hex digests, opaque
  per-run tokens and the harness adapters' own warning items (for example
  Codex's `--dangerously-bypass-hook-trust` notice) stripped. This
  repository's `scripts/check/offline.py` emits the frame for its failing
  stage; a project whose paid targets never print either frame simply falls
  back, so it still gets a discriminating signature.
  """

  @frame_tag "KOGEN_FAILURE_SIGNATURE"
  @head_limit 320
  @primary_default_limit 2_000
  @tail_lines 40
  # Lines kept above a `make: *** [t] Error N` marker: the target's own message
  # (`echo "X is missing. Required exact content: Y"`) carries no marker word
  # and sits just above it.
  @lead_lines 15
  @digest_tail_lines 20

  @exunit_header_re ~r/^[ \t]*\d+\)[ \t]+test .+?\(\S+\)[ \t]*\n[ \t]*\S+\.exs?:\d+/m
  @generic_marker_re ~r/error|fail|assert/i

  @ansi_re ~r/\e\[[0-9;]*[a-zA-Z]/
  @seed_re ~r/(--seed\s+\d+|Randomized with seed\s+\d+)/
  @finished_re ~r/Finished in [0-9.]+ seconds[^\n]*/
  @duration_re ~r/\b\d+(\.\d+)?s\b/
  @iso_ts_re ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?/
  @tmp_path_re Regex.compile!(
                 "(/private/tmp/\\S*|/var/folders/\\S*|\\S*compatibility-\\d+-\\d+\\S*|\\S*kogen-[a-zA-Z-]+-\\d{9,}[-\\S]*)"
               )
  # A per-run fixture directory named with an epoch (9+ digits) and any
  # pid or port suffix, for example `shaping-evaluation-1790357780712-586`.
  @run_dir_re ~r/[A-Za-z0-9_.]+(?:-[A-Za-z]+)*-\d{9,}(?:-\d+)*/
  @port_re ~r/\b(localhost|127\.0\.0\.1|0\.0\.0\.0):\d{2,5}\b/
  @isolated_token_re ~r/KOGEN_ISOLATED_COMPLETION\t\S+.*$/m
  @hex_digest_re ~r/\b[0-9a-f]{12,}\b/
  @codex_bypass_re ~r/^.*--dangerously-bypass-hook-trust.*\n?/m

  def derive(cycle, context, catalog, previous \\ [])

  def derive(%{"status" => "passed"}, _context, _catalog, _previous), do: %{}

  def derive(cycle, context, catalog, previous) do
    receipts = cycle["receipts"] || []

    # A controller cycle can also fail outside a target receipt (catalog,
    # proof selector, target evidence or Candidate mutation).
    failed =
      Enum.find(receipts, &(not passed?(&1))) || cycle["failure"] || %{}

    build(cycle, failed, context, catalog, previous)
  end

  @doc """
  One signature per failed item of a cycle: every failed receipt, then every
  failure that has no receipt (catalog, proof, cancelled), each derived
  exactly as `derive/4` derives the first. Cancelled and not-started jobs are
  neither pass nor fail and get no signature.
  """
  @spec derive_all(map(), map(), map(), [map()]) :: [map()]
  def derive_all(cycle, context, catalog, previous \\ [])

  def derive_all(%{"status" => "passed"}, _context, _catalog, _previous), do: []

  def derive_all(cycle, context, catalog, previous) do
    receipts = cycle["receipts"] || []
    failed_receipts = Enum.reject(receipts, &passed?/1)
    covered = MapSet.new(failed_receipts, & &1["target"])

    failures = cycle["failures"] || List.wrap(cycle["failure"])

    loose =
      for failure <- failures,
          is_map(failure),
          not MapSet.member?(covered, failure["target"]) or failure["kind"] in ~w(proof catalog),
          do: failure

    items = failed_receipts ++ loose
    items = if items == [], do: [cycle["failure"] || %{}], else: items

    Enum.map(items, fn item ->
      signature = build(cycle, item, context, catalog, previous)
      if item["class"], do: Map.put(signature, "class", item["class"]), else: signature
    end)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp build(cycle, failed, context, catalog, previous) do
    receipts = cycle["receipts"] || []
    output = to_string(failed["output"] || failed["reason"] || "")
    target = failed["target"] || cycle["failed_target"] || "unknown"

    {digest, first_failure, error_head, source, reproduce} = signature(target, output)

    paid_index =
      Enum.find_index(
        context["targets"] || [],
        &(get_in(catalog, [:targets, &1, "provider_backed"]) == true)
      )

    failed_index = Enum.find_index(receipts, &(&1["target"] == target)) || 0

    signature = %{
      "candidate_id" => cycle["candidate_id"],
      "cycle" => cycle["sequence"],
      "target" => target,
      "cost_class" => get_in(catalog, [:targets, target, "cost_class"]) || "unknown",
      "first_failure" => first_failure,
      "error_head" => error_head,
      "digest" => digest,
      "source" => source,
      "reproduce" => reproduce,
      "before_first_paid" => is_nil(paid_index) or failed_index < paid_index
    }

    signature =
      if cycle["class"], do: Map.put(signature, "class", cycle["class"]), else: signature

    Map.put(signature, "repeated", Enum.any?(previous, &(&1["digest"] == digest)))
  end

  @doc "A stable fallback signature for failures that happen outside a gate cycle."
  def for_stop(category, reason) do
    normalized = reason |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()

    %{
      "digest" =>
        Base.encode16(:crypto.hash(:sha256, category <> "\n" <> normalized), case: :lower),
      "target" => category,
      "first_failure" => category,
      "error_head" => String.slice(normalized, 0, 320),
      "source" => "stop",
      "repeated" => false
    }
  end

  @doc """
  A bounded excerpt of the primary failure lines: the frame's fields when
  `output` carries one `KOGEN_FAILURE_SIGNATURE` frame, otherwise the first
  failure block found by generic markers (error, fail, assert) plus the
  output's tail, within `limit` characters. A tail alone is not enough (a
  failing assertion can sit hundreds of non-blank lines from the very end of
  a long receipt); the block starts where the failure itself starts and
  always runs to the end of `output`, so both are covered in one contiguous
  excerpt.
  """
  def primary_lines(output, limit \\ @primary_default_limit) when is_binary(output) do
    case parse_frame(output) do
      {:ok, stage, test_id, assertion, _reproduce} ->
        "stage: #{stage}\ntest: #{test_id}\nassertion: #{assertion}"
        |> String.slice(0, limit)

      :error ->
        output
        |> failure_tail()
        |> bound_primary(output, limit)
    end
  end

  defp signature(target, output) do
    case parse_frame(output) do
      {:ok, stage, test_id, assertion, reproduce} ->
        frame_signature(target, stage, test_id, assertion, reproduce)

      :error ->
        tail_signature(target, output)
    end
  end

  defp frame_signature(target, stage, test_id, assertion, reproduce) do
    digest = sha256(Enum.join([target, stage || "", test_id || "", assertion || ""], "\n"))

    {digest, test_id || stage || target, bounded_text(assertion || stage || ""), "frame",
     reproduce}
  end

  # The digest is over the normalized last `@digest_tail_lines` non-blank
  # lines, not the whole failure block: a long failure block (for example an
  # isolated re-run's embedded raw tool-call transcript, btwokrNx) carries
  # incidental, non-reproducible content between the failure header and the
  # output's true end, which would otherwise keep two receipts of the exact
  # same real failure from collapsing. `primary_lines/2` (the resume prompt's
  # excerpt) uses the larger, header-anchored block instead, since display
  # needs the assertion itself, not just deduplication.
  defp tail_signature(target, output) do
    digest_source = output |> normalize() |> last_nonblank_lines(@digest_tail_lines)
    digest = sha256(target <> "\n" <> digest_source)
    {digest, first_identity(output, target), bounded_text(failure_tail(output)), "tail", nil}
  end

  defp passed?(%{"status" => status}) when is_binary(status), do: status in ["passed", "pass"]
  defp passed?(receipt), do: receipt["exit_code"] == 0

  # `KOGEN_FAILURE_SIGNATURE<TAB>{"stage":…,"test_id":…,"assertion":…}`
  # (README, scripts/check/README.md). The controller never parses
  # offline.py's or ExUnit's own output to build this; it only reads the
  # frame a target already emitted.
  defp parse_frame(output) do
    with [_, json] <- Regex.run(~r/^#{@frame_tag}\t(.+)$/m, output),
         {:ok, %{"stage" => stage, "test_id" => test_id, "assertion" => assertion} = frame} <-
           Jason.decode(json) do
      reproduce = frame["reproduce"]
      {:ok, stage, test_id, assertion, reproduce}
    else
      _ -> :error
    end
  end

  # The failure tail: from the start of the first ExUnit failure header (or,
  # absent one, the first line hit by a generic error/fail/assert marker) to
  # the end of `output`; absent either, the last `@tail_lines` non-blank
  # lines. Contiguous to the end so it always also carries "the output's
  # tail" (a2sPFUvF cycle 2: the assertion sits 232 of 262 non-blank lines
  # from the end; a fixed-size tail window alone would miss it).
  defp failure_tail(output) do
    case Regex.run(@exunit_header_re, output) do
      [block | _] -> from_first_occurrence(output, block)
      nil -> generic_marker_tail(output) || last_nonblank_lines(output, @tail_lines)
    end
  end

  defp from_first_occurrence(output, needle) do
    case String.split(output, needle, parts: 2) do
      [_pre, rest] -> needle <> rest
      _ -> output
    end
  end

  defp generic_marker_tail(output) do
    lines = String.split(output, "\n")

    case Enum.find_index(lines, &Regex.match?(@generic_marker_re, &1)) do
      nil -> nil
      index -> lines |> Enum.drop(lead_start(lines, index)) |> Enum.join("\n")
    end
  end

  # When the first marker is make's own `make: *** [t] Error N` line, the
  # target's echoed message is the lines just above it.
  defp lead_start(lines, index) do
    if String.starts_with?(Enum.at(lines, index), "make"),
      do: max(index - @lead_lines, 0),
      else: index
  end

  defp last_nonblank_lines(output, n) do
    output
    |> String.split("\n")
    |> Enum.filter(&(String.trim(&1) != ""))
    |> Enum.take(-n)
    |> Enum.join("\n")
  end

  defp bound_primary(tail, raw_output, limit) do
    if String.length(tail) <= limit do
      tail
    else
      block_budget = max(div(limit * 7, 10), 1)
      separator = "\n...\n"
      tail_budget = max(limit - block_budget - String.length(separator), 0)
      block_part = String.slice(tail, 0, block_budget)
      output_tail_part = String.slice(raw_output, -tail_budget, tail_budget)
      block_part <> separator <> output_tail_part
    end
  end

  defp normalize(text) do
    text
    |> strip_ansi()
    |> then(&Regex.replace(@seed_re, &1, "<SEED>"))
    |> then(&Regex.replace(@finished_re, &1, "Finished in <DURATION>"))
    |> then(&Regex.replace(@duration_re, &1, "<DUR>s"))
    |> then(&Regex.replace(@iso_ts_re, &1, "<TS>"))
    |> then(&Regex.replace(@tmp_path_re, &1, "<TMPPATH>"))
    |> then(&Regex.replace(@run_dir_re, &1, "<RUNDIR>"))
    |> then(&Regex.replace(@port_re, &1, "\\1:<PORT>"))
    |> then(&Regex.replace(@isolated_token_re, &1, "KOGEN_ISOLATED_COMPLETION <NORMALIZED>"))
    |> then(&Regex.replace(@hex_digest_re, &1, "<HEX>"))
    |> then(&Regex.replace(@codex_bypass_re, &1, ""))
  end

  defp strip_ansi(text), do: Regex.replace(@ansi_re, text, "")

  defp bounded_text(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @head_limit)
  end

  defp first_identity(output, fallback) do
    case Regex.run(~r/(?:test\/[^:\s]+(?::\d+)?|(?:mix|python3?|make) [^\n]+)/, output) do
      [match | _] -> String.slice(match, 0, 160)
      _ -> fallback
    end
  end

  defp sha256(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
end
