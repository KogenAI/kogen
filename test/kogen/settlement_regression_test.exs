Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.SettlementRegressionTest do
  @moduledoc """
  The former defect this file protects against was a corrected Stop block
  masquerading as a completed turn: a Developer turn whose `check` still
  failed was nonetheless treated as settled. Under the controller the
  equivalent protection is: a Developer turn whose first controller
  verification cycle fails is resumed, and only a later *passing* controller
  cycle on the same Candidate ever settles the turn. `legacy: true` drives a
  fake Developer that ignores the controller's resume (it never repairs the
  ignored `.kogen/runtime/kogen_fake_break` marker the resumed session is
  handed) and must therefore exhaust verification retries and never reach
  Review; the controller decides this, not the fake. `legacy: false` drives
  the well-behaved fake, which repairs the marker on resume and settles once
  a later cycle genuinely passes, even though an intermediate cycle fails
  again with a distinguishable sentinel that must never be read as success.
  """
  use ExUnit.Case, async: true, parameterize: [%{legacy: true}, %{legacy: false}]

  @slug "fake-shaped-intent"
  @sentinel "corrected-check-negative-control"

  test "a corrected Check block cannot masquerade as a completed Developer turn", %{
    legacy: legacy
  } do
    fixture = Kogen.CompiledFixture.create!(File.cwd!(), "settlement-negative")
    on_exit(fn -> File.rm_rf!(fixture) end)
    fake = Path.join(fixture, "test/support/fake_codex")

    # `check` fails on cycle 1 because the fake's fresh Developer turn leaves
    # the ignored marker; it fails again on cycle 2 regardless of the marker
    # (the negative-control sentinel, standing in for a "corrected" block
    # that is still broken); only a Candidate whose marker is gone and whose
    # cycle isn't the sentinel cycle passes. A well-behaved fake resume
    # removes the marker; the legacy (never-fixes) fake, driven by
    # FAKE_CHECK_FAIL_ALWAYS below, never does.
    File.write!(Path.join(fixture, "Makefile"), """
    .PHONY: check
    check:
    \t@n=0; [ ! -f .kogen/runtime/check-count ] || n=$$(cat .kogen/runtime/check-count); n=$$((n+1)); echo $$n > .kogen/runtime/check-count; if [ $$n -eq 2 ]; then echo #{@sentinel}; exit 1; fi
    \t@test ! -f .kogen/runtime/kogen_fake_break
    """)

    Kogen.VerificationFixture.install!(fixture)
    File.write!(Path.join(fixture, "dummy.txt"), "")

    # Build admission copies control deps/ into each Candidate.

    File.mkdir_p!(Path.join(fixture, "deps"))

    git!(fixture, ["init", "-q", "-b", "main"])
    git!(fixture, ["config", "user.name", "Kogen Fixture"])
    git!(fixture, ["config", "user.email", "fixture@example.invalid"])
    git!(fixture, ["add", "-A"])
    git!(fixture, ["commit", "-qm", "baseline"])
    parent = git!(fixture, ["rev-parse", "HEAD"])

    # These controls begin at Check settlement. The connected public Shape,
    # approval and Build contract remains covered in LifecycleTest.
    approved = Path.join(fixture, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(approved)

    File.write!(Path.join(approved, "intent.yaml"), """
    id: 01960000-0000-7000-8000-00000000cafe
    slug: #{@slug}
    title: Settlement negative control
    may_change_guarded_paths: [dummy.txt]
    """)

    File.write!(Path.join(approved, "scenarios.yaml"), """
    - id: corrected-check
      given: a bounded check that keeps failing after a first controller resume
      when: the controller settles verification for the Developer's turn
      then: only a later genuinely-passing controller cycle settles it
      wrong_result: a still-failing check is read as a completed, settled turn
      verified_by: [check]
      evidence: retained controller verification cycles and receipts
    """)

    # A first-review accept (matching the fresh Developer's dummy.txt write)
    # keeps this fixture scoped to controller verification retries, with no
    # Reviewer-driven outer rework in play.
    File.write!(
      Path.join(approved, "requirement.json"),
      Jason.encode!(%{"path" => "dummy.txt", "expected" => "initial fixture value"})
    )

    Kogen.VerificationFixture.install!(fixture)

    env = [
      {"KOGEN_HARNESS", fake},
      {"KOGEN_RAW_LOG_DIR", Path.join(fixture, ".kogen/runtime/raw")}
    ]

    # `legacy: true` reproduces the former fake's exact defect in controller
    # terms: it ignores the controller's resume and never repairs the
    # Candidate, so every cycle keeps failing. `legacy: false` is the
    # well-behaved fake: it repairs the marker on its first controller resume.
    env = if legacy, do: [{"FAKE_CHECK_FAIL_ALWAYS", "1"} | env], else: env

    {output, status} = Kogen.CompiledFixture.mix_task!(fixture, ["kogen.build", @slug], env)

    record =
      fixture
      |> Path.join(".kogen/runtime/scenario-tracking/*/record.json")
      |> Path.wildcard()
      |> List.first()
      |> File.read!()
      |> Jason.decode!()

    assert length(record["attempts"]) == 1,
           "a verification failure must never consume an outer resumption"

    [attempt] = record["attempts"]
    cycles = get_in(attempt, ["verification", "cycles"]) || []
    assert length(cycles) == 3, "expected two failed cycles then a decisive third"
    [cycle1, cycle2, cycle3] = cycles
    assert cycle1["status"] == "failed"
    assert cycle2["status"] == "failed"

    assert Enum.any?(cycle2["receipts"], &String.contains?(&1["output"] || "", @sentinel)),
           "the sentinel cycle must genuinely run and fail, never be masked as a pass"

    if legacy do
      assert status == 1, output
      assert output =~ "verification retries exhausted"
      assert cycle3["status"] == "failed"
      assert attempt["verification"]["terminal_state"] == "exhausted"
      assert record["status"] == "failed"

      assert git!(fixture, ["rev-parse", "HEAD"]) == parent,
             "an exhausted verification must never commit"

      refute File.exists?(Path.join(fixture, ".kogen/intents/complete/#{@slug}"))

      refute File.exists?(Path.join(fixture, ".kogen/runtime/fake-reviewer-calls")),
             "exhausted verification must stop before Review"
    else
      assert status == 0, output
      assert cycle3["status"] == "passed"
      assert attempt["verification"]["terminal_state"] == "passed"
      assert git!(fixture, ["rev-parse", "HEAD"]) != parent
      assert File.exists?(Path.join(fixture, ".kogen/intents/complete/#{@slug}"))

      # The published summary reports controller-decided failure kinds only;
      # the former Developer-handoff kinds no longer exist.
      summary =
        fixture
        |> Path.join(".kogen/intents/complete/#{@slug}/build-summary.json")
        |> File.read!()
        |> Jason.decode!()

      kinds = Enum.map(summary["attempts"], & &1["failure_kind"])
      assert List.last(kinds) == nil

      assert Enum.all?(
               kinds,
               &(&1 in [
                   nil,
                   "check_settlement",
                   "declared_target",
                   "review_rework",
                   "unfinished_work",
                   "cannot_comply",
                   "rework"
                 ])
             )

      refute Enum.any?(kinds, &(&1 in ["handoff_structure", "handoff_semantic"]))
    end
  end

  defp git!(fixture, args) do
    {output, 0} = System.cmd("git", args, cd: fixture, stderr_to_stdout: true)
    String.trim(output)
  end
end
