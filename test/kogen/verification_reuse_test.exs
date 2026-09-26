Code.require_file("../support/verification_cycle_fixture.ex", __DIR__)

defmodule Kogen.VerificationReuseTest do
  @moduledoc """
  Drives `Kogen.Build.Verification.initialize/6` and `run_cycle/4` directly
  against a git fixture (scenario `same-candidate-failed-only-retry`,
  `bound-per-target-receipts`, `no-special-gate-target`). Confirms that
  within one attempt a provider-backed target's passed receipt is reused only
  on a byte-identical Candidate id and catalog digest, that an offline target
  and a never-passed target always run fresh, that any Candidate byte change
  or new outer attempt reuses nothing, and that a forged or stale reuse
  binding is rejected by `validate_state/2`.
  """

  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.{Report, ReviewPacket, Verification}
  alias Kogen.VerificationCycleFixture, as: Fixture

  @retries 2

  setup do
    root = Fixture.new!()
    on_exit(fn -> File.rm_rf(root) end)

    plan = Fixture.plan(root, ["check", "a", "b"])
    env = Fixture.env(root, plan)
    {:ok, root: root, plan: plan, env: env}
  end

  test "cycle 1 fails at b; a byte-identical Candidate's cycle 2 runs check fresh, reuses a, and runs only b",
       %{root: root, plan: plan, env: env} do
    {:ok, exec0} =
      Verification.initialize(
        Fixture.tracking_path(root),
        "token-1",
        0,
        plan.targets,
        @retries,
        plan
      )

    candidate1 = Fixture.candidate_id!(root)
    Fixture.fail_b!(root)

    {:ok, exec1, state1} = Verification.run_cycle(exec0, "session-1", candidate1, env)
    assert state1["terminal_state"] == "pending"

    cycle1 = List.last(state1["cycles"])
    assert Enum.map(cycle1["receipts"], & &1["target"]) == ["check", "a", "b"]
    assert Enum.map(cycle1["receipts"], & &1["status"]) == ["passed", "passed", "failed"]
    assert cycle1["failure"]["kind"] == "target"
    assert cycle1["failure"]["target"] == "b"
    assert Fixture.calls(root) == ["check", "a", "b"]

    Fixture.reset_calls!(root)
    Fixture.clear_b_failure!(root)
    candidate2 = Fixture.candidate_id!(root)

    assert candidate2 == candidate1,
           "clearing a gitignored marker must not change the Candidate id"

    {:ok, exec2, state2} = Verification.run_cycle(exec1, "session-1", candidate2, env)
    assert state2["terminal_state"] == "passed"
    assert :ok = Verification.validate_state(state2, exec2)

    cycle2 = List.last(state2["cycles"])
    assert Enum.map(cycle2["receipts"], & &1["target"]) == ["check", "a", "b"]
    assert Enum.map(cycle2["receipts"], & &1["status"]) == ["passed", "passed", "passed"]

    # check always reruns and b (previously failed) is never reused; only a
    # (previously passed, same Candidate and catalog) is reused.
    assert Fixture.calls(root) == ["check", "b"]

    [check2, a2, b2] = cycle2["receipts"]
    refute Map.has_key?(check2, "reused_from")
    refute Map.has_key?(b2, "reused_from")
    assert a2["reused_from"]["cycle_sequence"] == 1
    assert a2["candidate_id"] == candidate1
    assert a2["catalog_sha256"] == cycle2["catalog_sha256"]

    receipts = Verification.final_receipts(state2)
    assert receipts == cycle2["receipts"]

    report =
      Report.build(%{
        contract: %{scenarios: [], risks: []},
        attempt_token: "token-1",
        candidate_id: candidate2,
        open_findings: [],
        changes: [],
        receipts: receipts
      })

    assert [reused] = report["reused_receipts"]
    assert reused["target"] == "a"
    assert reused["reused_from"]["cycle_sequence"] == 1

    record = %{
      "attempts" => [
        %{
          "number" => 1,
          "attempt_token" => "token-1",
          "receipts" => receipts,
          "handoff" => nil,
          "developer_notes" => nil,
          "verification_ledger" => nil,
          "base_suite" => nil,
          "superseded_objection" => nil
        }
      ],
      "scenarios" => [],
      "risks" => [],
      "findings" => []
    }

    packet_input = %{
      record: record,
      record_path: Path.join(root, "tracking.json"),
      record_bytes: "{}",
      candidate_id: candidate2,
      open_findings: []
    }

    assert {:ok, bytes} = ReviewPacket.build(packet_input)
    decoded = Jason.decode!(bytes)
    packet_a = Enum.find(decoded["receipts"], &(&1["target"] == "a"))
    assert packet_a["reused_from"]["cycle_sequence"] == 1
  end

  test "any changed byte forces every target to run fresh, even after a passed cycle", %{
    root: root,
    plan: plan,
    env: env
  } do
    {:ok, exec0} =
      Verification.initialize(
        Fixture.tracking_path(root),
        "token-2",
        0,
        plan.targets,
        @retries,
        plan
      )

    candidate1 = Fixture.candidate_id!(root)
    {:ok, exec1, state1} = Verification.run_cycle(exec0, "session-1", candidate1, env)
    assert state1["terminal_state"] == "passed"

    Fixture.reset_calls!(root)
    Fixture.edit_tracked_file!(root)
    candidate2 = Fixture.candidate_id!(root)
    refute candidate2 == candidate1

    {:ok, _exec2, state2} = Verification.run_cycle(exec1, "session-1", candidate2, env)
    cycle2 = List.last(state2["cycles"])

    assert Fixture.calls(root) == ["check", "a", "b"]
    assert Enum.all?(cycle2["receipts"], &(not Map.has_key?(&1, "reused_from")))
    assert Enum.all?(cycle2["receipts"], &(&1["candidate_id"] == candidate2))
  end

  test "a new outer attempt reuses nothing even on the identical Candidate", %{
    root: root,
    plan: plan,
    env: env
  } do
    {:ok, exec0} =
      Verification.initialize(
        Fixture.tracking_path(root),
        "token-3",
        0,
        plan.targets,
        @retries,
        plan
      )

    candidate = Fixture.candidate_id!(root)
    {:ok, exec1, _state1} = Verification.run_cycle(exec0, "session-1", candidate, env)
    _ = exec1

    {:ok, exec_new} =
      Verification.initialize(
        Fixture.tracking_path(root, "verification-cycle-build-outer-2"),
        "token-4",
        1,
        plan.targets,
        @retries,
        plan
      )

    Fixture.reset_calls!(root)
    {:ok, _exec, state} = Verification.run_cycle(exec_new, "session-2", candidate, env)
    cycle = List.last(state["cycles"])

    assert Fixture.calls(root) == ["check", "a", "b"]
    assert Enum.all?(cycle["receipts"], &(not Map.has_key?(&1, "reused_from")))
  end

  test "forged or stale reuse bindings are rejected by validate_state/2", %{
    root: root,
    plan: plan,
    env: env
  } do
    {:ok, exec0} =
      Verification.initialize(
        Fixture.tracking_path(root),
        "token-5",
        0,
        plan.targets,
        @retries,
        plan
      )

    candidate = Fixture.candidate_id!(root)
    Fixture.fail_b!(root)
    {:ok, exec1, _state1} = Verification.run_cycle(exec0, "session-1", candidate, env)
    Fixture.clear_b_failure!(root)

    {:ok, exec2, state2} = Verification.run_cycle(exec1, "session-1", candidate, env)
    assert :ok = Verification.validate_state(state2, exec2)

    for mutation <- [
          {"candidate_id", "some-other-candidate"},
          {"catalog_sha256", "0" |> String.duplicate(64)},
          {"context_sha256", "1" |> String.duplicate(64)}
        ] do
      {field, value} = mutation
      mutated = tamper_reused_receipt(state2, &Map.put(&1, field, value))
      assert {:error, _reason} = Verification.validate_state(mutated, exec2), field
    end

    mutated_cycle_sequence =
      tamper_reused_receipt(state2, &Map.put(&1, "cycle_sequence", 99))

    assert {:error, _reason} = Verification.validate_state(mutated_cycle_sequence, exec2)

    for bad_sequence <- [0, 2, 99] do
      mutated_origin =
        tamper_reused_receipt(state2, fn receipt ->
          put_in(receipt, ["reused_from", "cycle_sequence"], bad_sequence)
        end)

      assert {:error, _reason} = Verification.validate_state(mutated_origin, exec2),
             "bad_sequence=#{bad_sequence}"
    end
  end

  defp tamper_reused_receipt(state, fun) do
    update_in(state, ["cycles"], &tamper_last_cycle(&1, fun))
  end

  defp tamper_last_cycle(cycles, fun) do
    List.update_at(cycles, -1, &tamper_cycle_receipts(&1, fun))
  end

  defp tamper_cycle_receipts(cycle, fun) do
    update_in(cycle, ["receipts"], &Enum.map(&1, fn receipt -> tamper_receipt(receipt, fun) end))
  end

  defp tamper_receipt(receipt, fun) do
    if Map.has_key?(receipt, "reused_from"), do: fun.(receipt), else: receipt
  end
end
