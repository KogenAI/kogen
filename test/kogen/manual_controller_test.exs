defmodule Kogen.ManualControllerTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.AcceptanceJoin

  @ctx "ctx-digest-1"
  @tree "tree-T"

  defp join_inputs(overrides \\ %{}) do
    Map.merge(
      %{
        tree: @tree,
        context_digest: @ctx,
        offline: %{tree: @tree, context_digest: @ctx, status: "passed", sha256: "off"},
        selected_offline_targets: ["check", "proof-selector"],
        offline_target_receipts: [
          %{
            target: "check",
            tree: @tree,
            context_digest: @ctx,
            status: "passed",
            sha256: "off-check"
          },
          %{
            target: "proof-selector",
            tree: @tree,
            context_digest: @ctx,
            status: "passed",
            sha256: "off-proof"
          }
        ],
        selected_targets: ["t1"],
        target_receipts: [
          %{target: "t1", tree: @tree, context_digest: @ctx, status: "passed", sha256: "r1"}
        ],
        scenarios: %{"s1" => true},
        findings: [],
        verdict: %{
          session: "rev-1",
          verdict: "accept",
          tree: @tree,
          provisional: false,
          final: true
        },
        settlement: %{seq: 10, tree: @tree, receipt_digests: ["off", "r1"]},
        addendum: %{
          session: "rev-2",
          tree: @tree,
          seq: 11,
          cited_digests: ["r1", "off"],
          outcome: "confirm"
        }
      },
      overrides
    )
  end

  defp rebind(inputs, tree) do
    fix = fn m -> Map.put(m, :tree, tree) end

    inputs
    |> Map.put(:tree, tree)
    |> Map.update!(:offline, fix)
    |> Map.update!(:offline_target_receipts, &Enum.map(&1, fix))
    |> Map.update!(:target_receipts, &Enum.map(&1, fix))
    |> Map.update!(:verdict, fix)
    |> Map.update!(:settlement, fix)
    |> Map.update!(:addendum, fix)
  end

  describe "AcceptanceJoin" do
    test "all good is ok" do
      assert :ok = AcceptanceJoin.check(join_inputs())
    end

    test "the persisted JSON join round-trips without weakening bindings" do
      decoded = join_inputs() |> Jason.encode!() |> Jason.decode!()

      assert :ok = AcceptanceJoin.check(decoded)

      assert AcceptanceJoin.receipt_digests(decoded) ==
               AcceptanceJoin.receipt_digests(join_inputs())

      stale = put_in(decoded, ["offline", "tree"], "old")
      assert {:refuse, reasons} = AcceptanceJoin.check(stale)
      assert Keyword.has_key?(reasons, :stale_offline_tree)
    end

    test "stale tree receipt is refused" do
      stale =
        put_in(join_inputs().target_receipts, [
          %{target: "t1", tree: "old", context_digest: @ctx, status: "passed", sha256: "r1"}
        ])

      assert {:refuse, reasons} = AcceptanceJoin.check(stale)
      assert Enum.any?(reasons, &match?({:stale_target_receipt, %{target: "t1"}}, &1))
    end

    test "offline receipt for another tree or context is refused" do
      inputs =
        put_in(join_inputs().offline, %{
          tree: "old",
          context_digest: "c0",
          status: "passed",
          sha256: "off"
        })

      assert {:refuse, reasons} = AcceptanceJoin.check(inputs)
      assert Keyword.has_key?(reasons, :stale_offline_tree)
      assert Keyword.has_key?(reasons, :stale_offline_context)
    end

    test "missing, unexpected, and duplicate offline target receipts are refused" do
      [check, proof] = join_inputs().offline_target_receipts
      missing = put_in(join_inputs().offline_target_receipts, [check])
      assert {:refuse, reasons} = AcceptanceJoin.check(missing)
      assert {:missing_offline_target_receipt, "proof-selector"} in reasons

      unexpected_receipt = %{check | target: "other"}
      unexpected = put_in(join_inputs().offline_target_receipts, [check, unexpected_receipt])
      assert {:refuse, reasons} = AcceptanceJoin.check(unexpected)
      assert {:unexpected_offline_target_receipt, "other"} in reasons

      duplicate = put_in(join_inputs().offline_target_receipts, [check, check])
      assert {:refuse, reasons} = AcceptanceJoin.check(duplicate)
      assert Enum.any?(reasons, &match?({:invalid_offline_target_ids, _}, &1))

      failed_receipt = %{check | status: "failed"}
      failed = put_in(join_inputs().offline_target_receipts, [failed_receipt, proof])
      assert {:refuse, reasons} = AcceptanceJoin.check(failed)
      assert {:offline_target_not_passed, "check"} in reasons
    end

    test "duplicate and unselected live target receipts are refused" do
      [r1] = join_inputs().target_receipts

      duplicate = put_in(join_inputs().target_receipts, [r1, r1])
      assert {:refuse, reasons} = AcceptanceJoin.check(duplicate)
      assert {:duplicate_target_receipt, "t1"} in reasons

      extra = put_in(join_inputs().target_receipts, [r1, %{r1 | target: "t9", sha256: "r9"}])
      assert {:refuse, reasons} = AcceptanceJoin.check(extra)
      assert {:unexpected_target_receipt, "t9"} in reasons

      only_unselected = put_in(join_inputs().target_receipts, [%{r1 | target: "t9"}])
      assert {:refuse, reasons} = AcceptanceJoin.check(only_unselected)
      assert {:missing_target_receipt, "t1"} in reasons
      assert {:unexpected_target_receipt, "t9"} in reasons

      unselected_all = put_in(join_inputs().selected_targets, [])
      assert {:refuse, reasons} = AcceptanceJoin.check(unselected_all)
      assert {:unexpected_target_receipt, "t1"} in reasons
    end

    test "offline target selections cannot be omitted" do
      inputs = join_inputs() |> Map.delete(:selected_offline_targets)
      assert {:refuse, reasons} = AcceptanceJoin.check(inputs)

      assert {:invalid_offline_target_ids, %{field: :selected_offline_targets, reason: :missing}} in reasons
    end

    test "provisional verdict for T used on T' is refused" do
      inputs = join_inputs() |> rebind("T-prime")

      inputs =
        put_in(inputs.verdict, %{
          session: "r",
          verdict: "accept",
          tree: @tree,
          provisional: true,
          final: false
        })

      assert {:refuse, reasons} = AcceptanceJoin.check(inputs)
      assert Keyword.has_key?(reasons, :provisional_verdict)
      assert Keyword.has_key?(reasons, :verdict_wrong_tree)
    end

    test "missing addendum" do
      assert {:refuse, [{:missing_addendum, nil}]} =
               AcceptanceJoin.check(Map.delete(join_inputs(), :addendum))
    end

    test "addendum digest mismatch" do
      inputs = put_in(join_inputs().addendum.cited_digests, ["off"])
      assert {:refuse, reasons} = AcceptanceJoin.check(inputs)
      assert Keyword.has_key?(reasons, :addendum_digest_mismatch)
    end

    test "addendum before settlement" do
      inputs = put_in(join_inputs().addendum.seq, 10)
      assert {:refuse, reasons} = AcceptanceJoin.check(inputs)
      assert Keyword.has_key?(reasons, :addendum_not_after_settlement)
    end

    test "open blocker, missing target receipt, unsatisfied scenario and object addendum are all listed" do
      inputs =
        join_inputs(%{
          findings: [
            %{id: "f", blocking: true, status: "open"},
            %{id: "n", blocking: false, status: "open"}
          ],
          target_receipts: [],
          scenarios: %{"s1" => "trust me"}
        })

      inputs = put_in(inputs.addendum.outcome, "object")
      assert {:refuse, reasons} = AcceptanceJoin.check(inputs)
      assert {:open_blocking_finding, "f"} in reasons
      refute {:open_blocking_finding, "n"} in reasons
      assert {:missing_target_receipt, "t1"} in reasons
      assert {:scenario_unsatisfied, "s1"} in reasons
      assert {:addendum_not_confirm, "object"} in reasons
    end

    test "failed offline and failed target receipt" do
      inputs = put_in(join_inputs().offline.status, "failed")

      inputs =
        put_in(inputs.target_receipts, [
          %{target: "t1", tree: @tree, context_digest: @ctx, status: "failed", sha256: "r1"}
        ])

      assert {:refuse, reasons} = AcceptanceJoin.check(inputs)
      assert {:offline_not_passed, "failed"} in reasons
      assert {:target_not_passed, "t1"} in reasons
    end

    test "non-map inputs are refused" do
      assert {:refuse, [{:invalid_inputs, _}]} = AcceptanceJoin.check("success")
    end
  end
end
