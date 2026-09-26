Code.require_file("../support/scripted_build_fixture.ex", __DIR__)

defmodule Kogen.VerificationOwnershipLifecycleTest do
  @moduledoc """
  Scenario `controller-owns-verification`: a complete fake-harness Build
  through `Kogen.Build`, with real Make targets and a git fixture, shows a
  controller-owned failed-then-passed verification cycle pair across a
  resume of the same Developer session, followed by Review and Commit.

  This is also one of the three catalog rehearsals `scripts/check/rehearsals.exs`
  selects by id and runs inside `check` (scenario `stop-route-bootstrap-only`):
  it must keep emitting the rehearsal trace identities
  `Kogen.Build.Contract.load`, `Kogen.Build.Verification.initialize` and
  `Kogen.Build.Verification.settle` under `KOGEN_REHEARSAL_TRACE`, verified with
  `KOGEN_REHEARSAL_TRACE=/tmp/trace.txt mix test --exclude live
  test/kogen/verification_ownership_lifecycle_test.exs`.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.ScriptedBuildFixture, as: Fixture

  test "Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework" do
    dir = Fixture.fixture!()

    # `scripts/check/rehearsals.exs` runs this test with an externally
    # supplied `KOGEN_REHEARSAL_TRACE`; a standalone run gets a private path
    # instead so the rehearsal-trace assertion below is always exercised.
    {trace_path, owns_trace?} =
      case System.get_env("KOGEN_REHEARSAL_TRACE") do
        nil ->
          path =
            Path.join(
              System.tmp_dir!(),
              "kogen-rehearsal-trace-#{System.unique_integer([:positive])}"
            )

          System.put_env("KOGEN_REHEARSAL_TRACE", path)
          {path, true}

        path ->
          {path, false}
      end

    on_exit(fn ->
      if owns_trace? do
        System.delete_env("KOGEN_REHEARSAL_TRACE")
        File.rm(trace_path)
      end
    end)

    # A failed-then-passed controller verification cycle pair across a resume
    # of the same Developer session (the fixture's `check` fails while
    # `.kogen/runtime/fail-check` exists, on the Developer's first call only),
    # a fresh Reviewer, and a Commit.
    assert :ok = Fixture.run(dir, fail_first: [1], reviews: "accept")

    tracking = Fixture.record!(dir)
    [attempt] = tracking["attempts"]

    assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) == ["failed", "passed"]
    assert attempt["outcome"] == "settled"

    # The controller, not Stop, resumed the exact Developer session and ran
    # every cycle as its own children.
    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "verification-resumes")) == "1"

    verification_resume =
      File.read!(Kogen.CandidateFixture.fake_state(dir, "verification-resume-1"))

    assert String.starts_with?(
             verification_resume,
             "Controller verification failed after your turn"
           )

    assert verification_resume =~ "`make check` failed"

    # Review ran once and accepted; the Build reached Commit.
    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "reviews")) == "1"

    head_after =
      dir
      |> git!(["rev-parse", "HEAD"])

    refute head_after == ""

    complete_dir = Path.join(dir, ".kogen/intents/complete/#{Fixture.slug()}")
    assert File.dir?(complete_dir), "the Build must have committed the Approved Intent"
    refute File.dir?(Path.join(dir, ".kogen/intents/approved/#{Fixture.slug()}"))

    # The Stop hook is a bootstrap remnant here: it never settles, runs a
    # target or writes anything of its own.
    refute File.exists?(Path.join(dir, ".kogen/runtime/stop-check.log"))

    # This test is one of the catalog rehearsals `scripts/check/rehearsals.exs`
    # selects by id and runs inside `check`; it must keep emitting every
    # trace identity that rehearsal observes.
    trace = File.read!(trace_path)
    assert trace =~ "Kogen.Build.Contract.load\n"
    assert trace =~ "Kogen.Build.Verification.initialize\n"
    assert trace =~ "Kogen.Build.Verification.settle\n"
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir)
    String.trim(output)
  end
end
