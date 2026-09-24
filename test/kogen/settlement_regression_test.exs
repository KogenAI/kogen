Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.SettlementRegressionTest do
  use ExUnit.Case, async: true, parameterize: [%{legacy: true}, %{legacy: false}]

  @slug "fake-shaped-intent"
  @sentinel "corrected-check-negative-control"

  test "a corrected Check block cannot masquerade as a completed Developer turn", %{
    legacy: legacy
  } do
    fixture = Kogen.CompiledFixture.create!(File.cwd!(), "settlement-negative")
    on_exit(fn -> File.rm_rf!(fixture) end)
    fake = Path.join(fixture, "test/support/fake_codex")

    if legacy do
      # Reproduce the former fake's exact defect: ignore a blocking response
      # and emit turn.completed. This is only a private negative-control copy.
      File.write!(
        fake,
        String.replace(
          File.read!(fake),
          "exit 1 # unexpected-stop-response",
          "return 0 # legacy ignored block"
        )
      )
    end

    File.write!(Path.join(fixture, "Makefile"), """
    .PHONY: check
    check:
    \t@n=0; [ ! -f .kogen/runtime/check-count ] || n=$$(cat .kogen/runtime/check-count); n=$$((n+1)); echo $$n > .kogen/runtime/check-count; if [ $$n -eq 2 ]; then echo #{@sentinel}; exit 1; fi
    \t@test ! -f lib/kogen_fake_break.ex
    """)

    Kogen.VerificationFixture.install!(fixture)

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
    may_change_guarded_paths: [dummy.txt, reviewer-rework-marker.txt]
    """)

    File.write!(Path.join(approved, "scenarios.yaml"), """
    - id: corrected-check
      given: a bounded check that fails after the initial correction
      when: the fake Developer receives a blocking response
      then: it fails rather than reporting a completed turn
      wrong_result: a settlement failure consumes Reviewer rework budget
      verified_by: [check]
      evidence: retained hook response and exact launch counts
    """)

    Kogen.VerificationFixture.install!(fixture)

    {output, status} =
      Kogen.CompiledFixture.mix_task!(fixture, ["kogen.build", @slug], [
        {"KOGEN_HARNESS", fake},
        {"KOGEN_RAW_LOG_DIR", Path.join(fixture, ".kogen/runtime/raw")}
      ])

    if legacy do
      assert status == 0, output
      evidence = File.read!(Path.join(fixture, ".kogen/intents/complete/#{@slug}/evidence.md"))
      assert evidence =~ "Outer resumptions used: 1"

      record =
        fixture
        |> Path.join(".kogen/runtime/scenario-tracking/*/record.json")
        |> Path.wildcard()
        |> List.first()
        |> File.read!()
        |> Jason.decode!()

      assert Enum.any?(record["attempts"], fn attempt ->
               Enum.any?(get_in(attempt, ["verification", "cycles"]) || [], fn cycle ->
                 Enum.any?(cycle["receipts"], &String.contains?(&1["output"], @sentinel))
               end)
             end)

      assert record["status"] == "accepted"
    else
      assert status == 0, output
      assert git!(fixture, ["rev-parse", "HEAD"]) != parent
      assert File.exists?(Path.join(fixture, ".kogen/intents/complete/#{@slug}"))
    end

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

  defp git!(fixture, args) do
    {output, 0} = System.cmd("git", args, cd: fixture, stderr_to_stdout: true)
    String.trim(output)
  end
end
