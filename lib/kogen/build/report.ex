defmodule Kogen.Build.Report do
  @moduledoc """
  The controller-built Developer handoff report.

  After controller verification settles, Build derives the report deterministically
  from the Approved contract, the Candidate's Git changes relative to `HEAD`,
  the declared proof selectors and Kogen's own receipts. The Developer's final
  message is never parsed: it is recorded separately as unverified notes, and
  neither it nor Jev's reading can change any field here. The builder is total
  for well-formed controller inputs, so no handoff-format failure exists.
  """

  alias Kogen.Build.VerificationPlan

  @no_change_note "No declared affected path changed in this Candidate relative to HEAD. " <>
                    "This is a hint for the Reviewer, not a failure: preservation scenarios can " <>
                    "legitimately change nothing."

  @doc """
  Builds the report. `inputs` holds `:contract`, `:attempt_token`,
  `:candidate_id`, `:open_findings`, `:changes` (`[{path, change}]` with change
  `added`, `modified` or `deleted`), `:receipts` (the settled receipts, one
  uniform list in run order), optionally `:proofs`, `:labels` (scenario id to
  proof label), `:ledger` and `:base_suite`, and `:existing?` (a predicate
  for existing regular files). Any other input, such as the Developer's notes
  or Jev's outcome, is deliberately ignored.
  """
  @spec build(map()) :: map()
  def build(inputs) do
    VerificationPlan.trace("Kogen.Build.Report.build")
    contract = inputs.contract
    changes = Enum.sort(inputs.changes)
    existing? = Map.get(inputs, :existing?, &File.regular?/1)
    receipts = List.wrap(inputs.receipts)
    labels = Map.get(inputs, :labels, %{})
    proofs = List.wrap(Map.get(inputs, :proofs))

    %{
      "format" => "kogen-controller-handoff-report",
      "version" => 1,
      "built_by" => "controller",
      "attempt_token" => inputs.attempt_token,
      "candidate_id" => inputs.candidate_id,
      "developer_self_assessment" =>
        "none: the Developer's final message is recorded separately as unverified notes",
      "changed_affected_paths_meaning" =>
        "files under a scenario's declared affected paths that changed relative to HEAD; not where each behaviour lives",
      "receipts" => Enum.map(receipts, &receipt_binding/1),
      "reused_receipts" =>
        for(receipt <- receipts, receipt["reused_from"], do: receipt_binding(receipt)),
      "verification_ledger" => ledger_index(Map.get(inputs, :ledger)),
      "base_suite" => Map.get(inputs, :base_suite),
      "scenarios" =>
        Enum.map(
          contract.scenarios,
          &scenario_entry(&1, changes, receipts, existing?, labels, proofs)
        ),
      "risks" =>
        Enum.map(contract.risks, fn risk ->
          %{"id" => risk["id"], "scenario_ids" => risk["scenario_ids"]}
        end),
      "findings" =>
        Enum.map(inputs.open_findings, fn finding ->
          # The Reviewer's own evidence stays with the finding in the record;
          # the report cites only Candidate files and declared selectors.
          origin = Map.get(finding, "origin") || %{}

          %{
            "id" => finding["id"],
            "scenario_ids" => Map.get(finding, "scenario_ids", []),
            "reason" => origin["reason"],
            "origin_attempt_token" => origin["attempt_token"],
            "reviewer_session" => origin["reviewer_session"]
          }
        end)
    }
  end

  defp scenario_entry(scenario, changes, receipts, existing?, labels, proofs) do
    proof = scenario["proof"] || %{}
    affected = List.wrap(proof["affected_paths"])
    offline = List.wrap(proof["offline"])

    changed =
      for {path, change} <- changes, Enum.any?(affected, &under?(path, &1)) do
        entry = %{"path" => path, "change" => change}

        # Only an existing regular file is cited (and therefore snapshotted);
        # a deleted path is listed without a locator.
        if change != "deleted" and existing?.(path),
          do: Map.put(entry, "locator", "changed in Candidate relative to HEAD (#{change})"),
          else: entry
      end

    %{
      "id" => scenario["id"],
      "verified_by" => scenario["verified_by"],
      "offline_selectors" => Enum.map(offline, &selector(&1, existing?)),
      "paid_target" => proof["paid_target"],
      "proof_label" => Map.get(labels, scenario["id"], "integrity-not-configured"),
      "proof_runs" =>
        for(run <- proofs, run["scenario"] == scenario["id"], do: proof_binding(run)),
      "affected_paths" => affected,
      "changed_affected_paths" => changed,
      "affected_paths_note" => if(changed == [], do: @no_change_note),
      "receipts" =>
        receipts
        |> Enum.filter(&(&1["target"] in List.wrap(scenario["verified_by"])))
        |> Enum.map(&receipt_binding/1)
    }
  end

  defp selector(selector, existing?) do
    if existing?.(selector),
      do: %{"selector" => selector, "path" => selector, "locator" => "declared offline selector"},
      else: %{"selector" => selector}
  end

  defp under?(path, affected) do
    root = String.trim_trailing(affected, "/")
    path == root or String.starts_with?(path, root <> "/")
  end

  defp receipt_binding(nil), do: nil

  defp receipt_binding(receipt) do
    Map.take(
      receipt,
      ~w(target status exit_code candidate_id attempt_token session_id developer_session_id
         context_sha256 catalog_sha256 cycle_sequence started_at finished_at elapsed_ms
         log_path log_sha256 cleanup reused_from)
    )
  end

  defp proof_binding(run) do
    Map.take(
      run,
      ~w(scenario kind label status exit_code red red_kind base_commit overlay_sha256
         workspace_sha256 log_path log_sha256 cycle_sequence reused_from)
    )
  end

  # Only the index travels in the report; each full diff stays a retained
  # file bound by its locator and digest.
  defp ledger_index(nil), do: nil

  defp ledger_index(ledger) do
    Map.take(ledger, ~w(base_commit candidate_id items receipts_with_changed_runner catalog))
  end
end
