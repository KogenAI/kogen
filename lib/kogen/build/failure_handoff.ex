# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
defmodule Kogen.Build.FailureHandoff do
  @moduledoc """
  The prompt that resumes the same Developer after a failed verification
  cycle.

  It lists every failed receipt of the cycle (a failed `prepare` receipt
  included) with its failure class, retained receipt and log locators and
  digests, the target-evidence manifest and each manifest entry with its
  digest and a bounded excerpt of its own content, and a bounded excerpt of
  the primary failure lines (`Kogen.Build.FailureSignature.primary_lines/2`:
  the target's `KOGEN_FAILURE_SIGNATURE` frame when present, otherwise the
  first generic failure block plus the output's tail). It states the
  remaining offline and paid retries. Every manifest entry is treated alike;
  no target, file or output format is special. The whole prompt stays within
  a fixed bound, and the controller's context, state and history paths never
  appear in it.
  """

  alias Kogen.Build.FailureSignature

  @total_limit 24_000
  @primary_limit 2_400
  @entry_limit 600

  @doc """
  Renders the prompt. `input` holds `:cycle`, `:state`, `:context` (the
  attempt's verification context), `:control` (control root; retained paths
  are control-relative), `:candidate_root` (target evidence paths are
  Candidate-relative) and `:receipt_path` (a function of cycle sequence and
  receipt name returning the retained receipt file). Optional `:review_findings`
  is a list of `%{"id", "severity", "summary", "path"}` from the provisional
  Review of the same Candidate.

  The prompt is ONE aggregate: an index of every failed item (offline and
  live, with class, signature digest and evidence locator), one section per
  failed receipt or receipt-less failure, the Review findings, and the jobs
  that were cancelled or never started (neither pass nor fail). Within the
  bound, every section gets a fair share; anything cut is truncated in place
  or named as omitted, never dropped silently.
  """
  @spec render(map()) :: String.t()
  def render(input) do
    %{cycle: cycle, state: state, context: context} = input
    failure = cycle["failure"] || %{}
    failed = failed_receipts(cycle)

    header = """
    Controller verification failed after your turn (cycle #{cycle["sequence"]}, Candidate `#{cycle["candidate_id"]}`): #{target_line(failure)}.

    - Failure class: `#{cycle["class"] || failure["class"] || "paid"}`
    - Failed target: `#{failure["target"]}` (#{failure["kind"]})
    - Retained receipt: `#{primary_receipt(input, failed, failure)}`
    - Retained log: `#{absolute(failure["log_path"], input.control)}` (sha256 #{failure["log_sha256"]})
    #{budget_lines(state, context)}
    Read the logs, fix the Candidate, and end your turn. Kogen's Build controller runs the selected targets again after your turn; do not run them yourself. Offline targets always run before any `prepare` step or provider-backed target.
    """

    signature =
      cycle["signature"] || cycle["failure_signature"] ||
        FailureSignature.derive(cycle, context, input[:catalog] || %{}, [])

    first_failure = if signature == %{}, do: failure, else: signature
    target = first_failure["target"] || failure["target"] || "unknown"

    reproduce =
      first_failure["reproduce"] ||
        "run the command that `make #{target}` runs, whole and at its normal concurrency, not the one test alone; the controller runs `make #{target}` itself after your turn"

    first_block = first_failure_block(Map.put(first_failure, "reproduce", reproduce))

    heading = header <> first_block

    index = failure_index(failed, cycle, context, input)
    findings = findings_section(input[:review_findings])
    unsettled = unsettled_section(cycle)
    sections_heading = "\n## Failed receipts of this cycle\n\n"

    reserved =
      byte_size(heading) + byte_size(index) + byte_size(sections_heading) + byte_size(findings) +
        byte_size(unsettled)

    sections =
      failed
      |> Enum.map(fn {name, receipt} = entry ->
        {section_name(name, receipt), receipt_section(entry, input)}
      end)
      |> fit(@total_limit - reserved)

    heading <> index <> sections_heading <> sections <> findings <> unsettled
  end

  defp section_name(name, receipt), do: name || receipt["target"] || "unknown"

  @index_limit 3_000
  @index_line 300

  # One line per failed item, so the whole set is visible at a glance even
  # when the sections below must be cut.
  defp failure_index(failed, cycle, context, input) do
    lines =
      for {name, receipt} <- failed do
        sig =
          FailureSignature.derive(
            %{
              "candidate_id" => cycle["candidate_id"],
              "sequence" => cycle["sequence"],
              "receipts" => [],
              "failure" => receipt
            },
            context,
            input[:catalog] || %{},
            []
          )

        class = receipt["class"] || class_of(receipt)
        evidence = if receipt["log_path"], do: " log `#{receipt["log_path"]}`", else: ""

        bounded(
          "- `#{section_name(name, receipt)}` [#{class}] signature #{String.slice(to_string(sig["digest"]), 0, 12)}: #{sig["error_head"]}#{evidence}",
          @index_line
        )
      end

    "\n## All failures of this cycle (#{length(failed)})\n\n" <>
      bounded_lines(lines, @index_limit, "failed item(s)")
  end

  @findings_limit 3_000
  @finding_line 400

  defp findings_section(findings) when is_list(findings) and findings != [] do
    lines =
      for finding <- findings, is_map(finding) do
        path = if finding["path"], do: " (#{finding["path"]})", else: ""

        bounded(
          "- [#{finding["severity"] || "unspecified"}] #{finding["id"] || "?"}: #{finding["summary"]}#{path}",
          @finding_line
        )
      end

    "\n## Review findings (#{length(lines)})\n\nThe provisional Review of this same Candidate found these; they did not cancel any live target.\n\n" <>
      bounded_lines(lines, @findings_limit, "finding(s)")
  end

  defp findings_section(_findings), do: ""

  @unsettled_limit 1_500

  defp unsettled_section(cycle) do
    targets =
      for entry <- List.wrap(cycle["cancelled"]),
          do: "- `#{entry["target"]}`: #{entry["status"]} (#{entry["reason"]})"

    companions =
      for entry <- List.wrap(cycle["companions"]),
          entry["status"] in ~w(cancelled not_started error crashed),
          do: "- companion `#{entry["id"]}`: #{entry["status"]} (#{entry["reason"]})"

    case targets ++ companions do
      [] ->
        ""

      lines ->
        "\n## Cancelled or not started (neither pass nor fail)\n\n" <>
          bounded_lines(Enum.map(lines, &bounded(&1, 250)), @unsettled_limit, "item(s)")
    end
  end

  # Lines are kept whole in order until the bound; the rest are named by
  # count, never dropped silently.
  defp bounded_lines(lines, limit, noun) do
    {kept, _used} =
      Enum.reduce_while(lines, {[], 0}, fn line, {acc, used} ->
        cost = byte_size(line) + 1

        if used + cost <= limit - 80,
          do: {:cont, {acc ++ [line], used + cost}},
          else: {:halt, {acc, used}}
      end)

    omitted = length(lines) - length(kept)

    note =
      if omitted > 0,
        do: "- [#{omitted} further #{noun} omitted to stay within the prompt bound]\n",
        else: ""

    Enum.join(kept, "\n") <> if(kept == [], do: "", else: "\n") <> note
  end

  @doc "Renders the canonical first-failure block shared by rework and fresh prompts."
  def first_failure_block(signature) when is_map(signature) do
    reproduce =
      signature["reproduce"] ||
        "run the command that `make #{signature["target"]}` runs, whole and at its normal concurrency, not the one test alone; the controller runs `make #{signature["target"]}` itself after your turn"

    "\n## First failure\n\n" <>
      "- Target: #{signature["target"]}\n" <>
      "- First failure: #{signature["first_failure"]}\n" <>
      "- Error head: #{signature["error_head"]}\n" <>
      "- Reproduce: #{reproduce}\n\n" <>
      "Passes in isolation is not acceptable: reproduce the failure under the gate's concurrency and make it deterministic; an unchanged Candidate stops the Build.\n"
  end

  # Every failed receipt of the cycle, `prepare` receipts first (they run
  # before the paid targets), then target receipts in run order. A cycle that
  # failed before any receipt (catalog check, runner or proof failure) is
  # described by its failure alone.
  defp failed_receipts(cycle) do
    prepares =
      for receipt <- List.wrap(cycle["prepare"]),
          receipt["status"] == "failed",
          do: {"prepare-" <> receipt["target"], receipt}

    providers =
      for receipt <- List.wrap(cycle["provider_failures"]),
          do: {"provider-" <> receipt["target"], Map.put(receipt, "class", "provider")}

    targets =
      for receipt <- List.wrap(cycle["receipts"]),
          receipt["status"] == "failed" or is_binary(receipt["target_evidence_error"]),
          do: {receipt["target"], receipt}

    named = prepares ++ providers ++ targets

    covered =
      MapSet.new(for {_name, receipt} <- named, do: to_string(receipt["target"]))

    loose =
      for failure <- List.wrap(cycle["failures"]),
          is_map(failure),
          failure["kind"] not in ~w(target target_evidence runner prepare) or
            not MapSet.member?(covered, to_string(failure["target"])),
          do: {nil, failure}

    case named ++ loose do
      [] -> [{nil, cycle["failure"] || %{}}]
      list -> list
    end
  end

  defp primary_receipt(input, failed, failure) do
    case Enum.find(failed, fn {name, _receipt} -> name == failure["target"] end) ||
           Enum.find(failed, fn {name, _receipt} ->
             is_binary(name) and name == "prepare-" <> to_string(failure["target"])
           end) do
      {name, _receipt} when is_binary(name) ->
        input.receipt_path.(input.cycle["sequence"], name)

      _ ->
        "none (the cycle failed before `make #{failure["target"]}` produced a receipt)"
    end
  end

  defp target_line(failure) do
    case failure["kind"] do
      "target" -> "`make #{failure["target"]}` failed"
      "prepare" -> "the `prepare` step of `#{failure["target"]}` failed"
      "catalog" -> "the Candidate's verification-target catalog check failed"
      "proof" -> "the controller-run proof selectors of scenario `#{failure["target"]}` failed"
      kind -> "`#{failure["target"]}` failed (#{kind})"
    end
  end

  defp budget_lines(state, context) do
    paid = context["verification_retries"]
    paid_left = max(paid - (state["failures_since_pass"] || 0), 0)

    paid_line = "- Paid (`verification_retries`) retries left: #{paid_left} of #{paid}"

    case context["offline_retries"] do
      offline when is_integer(offline) ->
        left = max(offline - (state["offline_failures"] || 0), 0)
        "- Offline (`offline_retries`) retries left: #{left} of #{offline}\n" <> paid_line <> "\n"

      _ ->
        paid_line <> "\n"
    end
  end

  defp receipt_section({name, receipt}, input) do
    title = if name, do: "### `#{name}`", else: "### `#{receipt["target"]}`"

    receipt_line =
      if name,
        do: "- Receipt: `#{input.receipt_path.(input.cycle["sequence"], name)}`\n",
        else: ""

    class = receipt["class"] || class_of(receipt)

    """
    #{title}

    - Class: `#{class}`; exit code #{inspect(receipt["exit_code"])}; timed out #{inspect(receipt["timed_out"] || false)}
    #{receipt_line}- Log: `#{absolute(receipt["log_path"], input.control)}` (sha256 #{receipt["log_sha256"]})
    #{marker_line(receipt)}#{attempts_line(receipt)}#{prepare_line(receipt)}#{evidence_lines(receipt, input)}
    Primary failure lines:

    ```text
    #{FailureSignature.primary_lines(to_string(receipt["output"] || ""), @primary_limit)}
    ```
    """
  end

  defp class_of(%{"provider_backed" => true}), do: "paid"
  defp class_of(%{"provider_backed" => false}), do: "offline"
  defp class_of(_receipt), do: "unknown"

  defp marker_line(%{"marker" => %{"kind" => kind, "marker" => line}}),
    do: "- Provider marker (#{kind}): `#{bounded(line, 300)}`\n"

  defp marker_line(_receipt), do: ""

  # The same-tree retry keeps both attempts: the developer and the Reviewer
  # see the first failure as well as the rerun.
  defp attempts_line(%{"attempts" => [_ | _] = attempts}) do
    lines =
      Enum.map_join(attempts, "; ", fn a ->
        "#{a["attempt"]} #{a["status"]} (exit #{inspect(a["exit_code"])}, log `#{a["log_path"]}` sha256 #{a["log_sha256"]})"
      end)

    "- Attempts (same-tree retry): #{lines}\n"
  end

  defp attempts_line(_receipt), do: ""

  defp prepare_line(%{"prepare_result" => %{} = result}),
    do: "- Prepare result: `#{bounded(Jason.encode!(result), 400)}`\n"

  defp prepare_line(_receipt), do: ""

  defp evidence_lines(%{"target_evidence_error" => error}, _input) when is_binary(error),
    do: "- Target evidence error: #{bounded(error, 400)}\n"

  defp evidence_lines(%{"target_evidence" => evidence}, input) when is_map(evidence) do
    manifest = evidence["manifest"] || %{}
    root = input.candidate_root

    entries =
      Enum.map_join(List.wrap(evidence["required_evidence"]), fn entry ->
        """
          - `#{Path.expand(entry["path"], root)}` (sha256 #{entry["sha256"]})

            ```text
        #{indent(excerpt(entry), "        ")}
            ```
        """
      end)

    "- Evidence manifest: `#{Path.expand(manifest["path"] || "", root)}` (sha256 #{manifest["sha256"]})\n" <>
      entries
  end

  defp evidence_lines(_receipt, _input), do: ""

  defp excerpt(entry) do
    case Base.decode64(entry["content_base64"] || "") do
      {:ok, bytes} ->
        bytes = if String.valid?(bytes), do: bytes, else: String.replace_invalid(bytes)
        FailureSignature.primary_lines(bytes, @entry_limit)

      :error ->
        "(content unavailable)"
    end
  end

  defp indent(text, prefix),
    do: text |> String.split("\n") |> Enum.map_join("\n", &(prefix <> &1))

  # Fair allocation: every section gets an equal share of the bound, sections
  # smaller than their share keep their whole text and hand the difference to
  # the rest, and the rest are cut to their first lines. A section that could
  # not keep even @min_section bytes is not rendered, and is named in the
  # closing note (never silently dropped). Byte accounting covers each
  # section's joining newline and reserves room for the note.
  @omission_reserve 400
  @min_section 500
  @truncation_note "\n[section truncated]\n"

  defp fit(named, limit) do
    limit = max(limit - @omission_reserve, 0)
    keep_count = min(length(named), max(div(limit, @min_section), 1))
    {kept, dropped} = Enum.split(named, keep_count)
    shares = allocate(Enum.map(kept, fn {_name, text} -> byte_size(text) + 1 end), limit)

    rendered =
      for {{_name, text}, share} <- Enum.zip(kept, shares) do
        if byte_size(text) + 1 <= share do
          text
        else
          room = max(share - byte_size(@truncation_note) - 1, 0)
          byte_prefix(text, room) <> @truncation_note
        end
      end

    tail =
      case dropped do
        [] ->
          ""

        _ ->
          names = dropped |> Enum.map(&elem(&1, 0)) |> Enum.map_join(", ", &bounded(&1, 60))

          "\n[#{length(dropped)} further failed receipt(s) omitted to stay within the prompt bound: #{bounded(names, 300)}]\n"
      end

    Enum.join(rendered, "\n") <> tail
  end

  # Water-filling: ascending sizes take min(size, equal share of what is left).
  defp allocate([], _limit), do: []

  defp allocate(sizes, limit) do
    indexed = sizes |> Enum.with_index() |> Enum.sort()

    {shares, _left} =
      indexed
      |> Enum.with_index()
      |> Enum.reduce({%{}, limit}, fn {{size, position}, taken}, {acc, left} ->
        remaining = length(indexed) - taken
        share = min(size, div(left, remaining))
        {Map.put(acc, position, share), left - share}
      end)

    for position <- 0..(length(sizes) - 1), do: Map.fetch!(shares, position)
  end

  # The longest prefix of `text` within `bytes` bytes that ends on a
  # character boundary.
  defp byte_prefix(text, bytes) when byte_size(text) <= bytes, do: text

  defp byte_prefix(text, bytes) do
    prefix = binary_part(text, 0, max(bytes, 0))
    if String.valid?(prefix), do: prefix, else: byte_prefix(prefix, byte_size(prefix) - 1)
  end

  defp bounded(text, limit) do
    text = to_string(text)
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "…"
  end

  defp absolute(path, control) when is_binary(path), do: Path.expand(path, control)
  defp absolute(path, _control), do: path
end
