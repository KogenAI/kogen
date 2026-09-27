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
  receipt name returning the retained receipt file).
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

    first_block =
      "\n## First failure\n\n" <>
        "- Target: #{first_failure["target"]}\n" <>
        "- First failure: #{first_failure["first_failure"]}\n" <>
        "- Error head: #{first_failure["error_head"]}\n" <>
        "- Reproduce: #{reproduce}\n\n" <>
        "Passes in isolation is not acceptable: reproduce the failure under the gate's concurrency and make it deterministic; an unchanged Candidate stops the Build.\n"

    heading = header <> first_block <> "\n## Failed receipts of this cycle\n\n"

    sections =
      failed
      |> Enum.map(&receipt_section(&1, input))
      |> fit(@total_limit - byte_size(heading))

    heading <> sections
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

    case prepares ++ providers ++ targets do
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
    #{marker_line(receipt)}#{prepare_line(receipt)}#{evidence_lines(receipt, input)}
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

  # Sections are kept whole while they fit; the rest are cut to their first
  # lines, and anything beyond the bound is named, never silently dropped.
  # Byte accounting covers each section's joining newline and reserves room
  # for the omission note, so the rendered prompt never exceeds the bound.
  @omission_reserve 100
  @truncation_note "\n[section truncated]\n"

  defp fit(sections, limit) do
    limit = limit - @omission_reserve

    {kept, _used, omitted} =
      Enum.reduce(sections, {[], 0, 0}, fn section, {kept, used, omitted} ->
        cost = byte_size(section) + 1

        cond do
          used + cost <= limit ->
            {kept ++ [section], used + cost, omitted}

          used + 400 <= limit ->
            room = limit - used - byte_size(@truncation_note) - 1
            short = byte_prefix(section, room) <> @truncation_note
            {kept ++ [short], used + byte_size(short) + 1, omitted}

          true ->
            {kept, used, omitted + 1}
        end
      end)

    tail =
      if omitted > 0,
        do: "\n[#{omitted} further failed receipt(s) omitted to stay within the prompt bound]\n",
        else: ""

    Enum.join(kept, "\n") <> tail
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
