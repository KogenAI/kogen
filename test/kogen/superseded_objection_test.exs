Code.require_file("../support/scripted_build_fixture.ex", __DIR__)

defmodule Kogen.SupersededObjectionTest do
  @moduledoc """
  A confident Developer objection in an attempt whose settled controller
  verification passed after an earlier controller cycle of the same attempt
  failed is superseded: it no longer stops the Build, it is recorded on the
  attempt and it reaches the fresh Reviewer as a labelled advisory item in the
  review packet. Every other confident objection stops as cannot-comply. The
  Build route tests drive the real controller-written cycles, with a fake
  Developer that fixes the Candidate on the controller's resume of the same
  session, and a stubbed Jev transport.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.ReviewPacket
  alias Kogen.FakeJev
  alias Kogen.ScriptedBuildFixture, as: Fixture

  @prefix "Developer cannot comply as approved; return to Shaping:"
  @objection "I object: s-change cannot be met as approved; it needs a path outside the guarded list."
  @answers %{"objection:scenario:s-change" => ["objection", 0.95]}

  # `jev_answers` is one static override applied to every Jev call of the
  # Build, so it cannot express "no objection on the turn's first cycle,
  # then an objection once an earlier cycle has already failed" -- the only
  # shape that ever reaches `ReviewPacket.superseded_objection/4` under
  # `notes-and-selectors-before-verification`'s ordering. `jev_results`
  # sequences a distinct fake Jev HTTP response per call instead.
  defp no_objection_then_objection(no_objection_calls) do
    List.duplicate({200, FakeJev.answer_body(Fixture.jev_items())}, no_objection_calls) ++
      [
        {200,
         FakeJev.answer_body(Fixture.jev_items(), %{
           "objection:scenario:s-change" => {"objection", 0.95}
         })}
      ]
  end

  test "failed-then-passed Stop cycles in one attempt supersede the objection and reach Review" do
    dir = Fixture.fixture!()

    # Scenario `notes-and-selectors-before-verification`: Jev reads notes
    # before any cycle runs, so an objection already present on the turn's
    # very first cycle (no earlier failed cycle of this attempt to
    # supersede it) stops the Build at once. Supersession can only ever see
    # a failed-then-passed history, so Jev reads no objection on cycle 1's
    # own pre-check, then one on the resumed cycle's, after cycle 1 has
    # already failed for an unrelated reason (the `fail_first` marker).
    assert :ok =
             Fixture.run(dir,
               notes: [@objection],
               fail_first: [1],
               jev_results: no_objection_then_objection(1),
               edits: %{1 => "printf 'changed\\n' > dummy.txt"}
             )

    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "reviews")) == "1"
    [attempt] = Fixture.record!(dir)["attempts"]
    assert attempt["outcome"] == "settled"
    refute Map.has_key?(attempt, "cannot_comply")
    assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) == ["failed", "passed"]

    superseded = attempt["superseded_objection"]

    assert superseded["items"] == [
             %{"kind" => "scenario", "id" => "s-change", "confidence" => 0.95}
           ]

    assert superseded["confidences"] == %{"scenario:s-change" => 0.95}
    assert superseded["failed_cycle_sequences"] == [1]
    assert superseded["passing_cycle_sequence"] == 2
    assert superseded["threshold"] == 0.85
    assert superseded["attempt_token"] == attempt["attempt_token"]
    assert superseded["developer_session_id"] == attempt["developer_session_id"]
    assert superseded["candidate_id"] == attempt["candidate_id"]

    # The first Review packet was provisionally built before verification
    # settled, so it cannot claim the later-proven supersession.
    provisional_packet =
      Jason.decode!(File.read!(Kogen.CandidateFixture.fake_state(dir, "reviewer-packet-1.json")))

    assert provisional_packet["superseded_objection"] == nil

    # The settled evidence addendum resumes this Reviewer's session with a
    # packet containing the now-proven advisory; its accepted verdict is the
    # one joined with the settled receipts for publication.
    addendum = attempt["addendum_packet"]
    packet = Jason.decode!(File.read!(Path.expand(addendum["path"], dir)))

    assert packet["superseded_objection"]["label"] =~ "advisory"
    assert packet["superseded_objection"]["label"] =~ "Judge every scenario yourself"

    assert Map.delete(packet["superseded_objection"], "label") == superseded
    assert packet["developer_notes"] == @objection
    assert attempt["evidence_addendum"]["outcome"] == "confirm"
    assert attempt["acceptance_join"] == "passed"

    addendum_prompt =
      File.read!(Kogen.CandidateFixture.fake_state(dir, "reviewer-addendum-prompt-1"))

    assert addendum_prompt =~ Path.expand(addendum["path"], dir)
  end

  test "a single passing Stop cycle keeps an objection a cannot-comply stop" do
    dir = Fixture.fixture!()

    assert {:error, reason} = Fixture.run(dir, notes: [@objection], jev_answers: @answers)

    assert String.starts_with?(reason, @prefix)
    assert reason =~ "scenario `s-change` (Jev confidence 0.95)"
    assert reason =~ "Developer's notes: \"#{@objection}\""
    refute File.exists?(Kogen.CandidateFixture.fake_state(dir, "reviews"))
    [attempt] = Fixture.record!(dir)["attempts"]
    assert attempt["outcome"] == "cannot_comply"
    refute Map.has_key?(attempt, "superseded_objection")
    refute Map.has_key?(attempt, "review_packet")
  end

  # `check` is offline, so `fail_all: [1]` exhausts `offline_retries: 4`
  # (five consecutive failures) rather than `verification_retries`. The
  # objection is the last resumed cycle's own notes (cycle 1's, on the
  # turn's very first cycle, would instead stop at once as a plain
  # cannot-comply, before verification runs at all -- covered by
  # `pre_verification_settlement_test.exs`). Once any cycle of the attempt
  # has failed, an objection deferred past it stays the stop's reason when
  # verification then exhausts, so this attempt's exhaustion still surfaces
  # as `cannot_comply`, carrying the exhaustion detail, not a bare
  # exhaustion message that would hide the objection.
  test "exhausted verification with a lingering objection stops as cannot-comply, carrying the exhaustion detail" do
    dir = Fixture.fixture!()

    assert {:error, reason} =
             Fixture.run(dir,
               notes: [@objection],
               fail_all: [1],
               jev_results: no_objection_then_objection(4)
             )

    assert String.starts_with?(reason, @prefix)
    assert reason =~ "offline retries exhausted (offline_retries: 4) after cycle 5"
    refute File.exists?(Kogen.CandidateFixture.fake_state(dir, "reviews"))
    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "verification-resumes")) == "4"
    [attempt] = Fixture.record!(dir)["attempts"]

    assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) ==
             ~w(failed failed failed failed failed)

    assert attempt["outcome"] == "cannot_comply"
    refute Map.has_key?(attempt, "superseded_objection")
  end

  test "a failed cycle of an earlier attempt never supersedes a later first-cycle objection" do
    dir = Fixture.fixture!()
    items = Fixture.jev_items()

    assert {:error, reason} =
             Fixture.run(dir,
               notes: ["All scenarios are done.", @objection],
               reviews: "rework",
               fail_first: [1],
               # The rework continuation starts on the Candidate the Reviewer
               # just rejected. Change it before the second attempt's
               # pre-verification Jev check, which is where its objection
               # must stop the Build.
               edits: %{2 => "printf 'changed\\n' >> dummy.txt"},
               # Attempt 1 has two cycles (a failure the resume fixes), so
               # Jev is asked once before each; no `F1` finding exists yet.
               # Attempt 2's own first (and only) cycle is asked once more,
               # after the rework Review opened `F1`, this time with the
               # objection.
               jev_results: [
                 {200, FakeJev.answer_body(items)},
                 {200, FakeJev.answer_body(items)},
                 {200,
                  FakeJev.answer_body(Fixture.jev_items(["F1"]), %{
                    "objection:scenario:s-change" => {"objection", 0.95}
                  })}
               ]
             )

    assert String.starts_with?(reason, @prefix)
    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "reviews")) == "1"
    [first, second] = Fixture.record!(dir)["attempts"]
    assert Enum.map(first["verification"]["cycles"], & &1["status"]) == ["failed", "passed"]
    assert second["outcome"] == "cannot_comply"
    refute Map.has_key?(second, "superseded_objection")

    # The objection is on attempt 2's own first cycle, with no earlier
    # failed cycle of *this* attempt to supersede it, so the controller
    # stops at once, before that cycle ever runs.
    refute Map.has_key?(second, "verification")
  end

  test "an objection below the threshold is unchanged after failed-then-passed cycles" do
    dir = Fixture.fixture!()

    assert :ok =
             Fixture.run(dir,
               notes: [@objection],
               fail_first: [1],
               jev_answers: %{"objection:scenario:s-change" => ["objection", 0.84]}
             )

    [attempt] = Fixture.record!(dir)["attempts"]
    refute Map.has_key?(attempt, "superseded_objection")
    assert Fixture.reviewer_prompt!(dir, 1) =~ "possible objection (confidence 0.84)"

    packet =
      Jason.decode!(File.read!(Kogen.CandidateFixture.fake_state(dir, "reviewer-packet-1.json")))

    assert packet["superseded_objection"] == nil
  end

  describe "the superseded rule" do
    @binding %{attempt_token: "t1", developer_session_id: "dev", candidate_id: "c2"}
    @objections [%{"kind" => "scenario", "id" => "s", "confidence" => 1.0}]

    defp cycle(sequence, status, overrides \\ %{}) do
      Map.merge(
        %{
          "sequence" => sequence,
          "status" => status,
          "attempt_token" => "t1",
          "developer_session_id" => "dev",
          "candidate_id" => "c2"
        },
        overrides
      )
    end

    defp verification(cycles, terminal \\ "passed"),
      do: %{"terminal_state" => terminal, "cycles" => cycles}

    test "supersedes only a failed-then-passed history on the settled Candidate" do
      history = verification([cycle(1, "failed"), cycle(2, "failed"), cycle(3, "passed")])

      assert %{"failed_cycle_sequences" => [1, 2], "passing_cycle_sequence" => 3} =
               ReviewPacket.superseded_objection(history, @binding, @objections, 0.85)
    end

    test "every other history keeps the objection a stop" do
      for {label, history} <- [
            {"no objection", nil},
            {"only one cycle", verification([cycle(1, "passed")])},
            {"exhausted", verification([cycle(1, "failed"), cycle(2, "failed")], "exhausted")},
            {"final cycle failed", verification([cycle(1, "failed"), cycle(2, "failed")])},
            {"different attempt",
             verification([cycle(1, "failed", %{"attempt_token" => "t0"}), cycle(2, "passed")])},
            {"different session",
             verification([
               cycle(1, "failed", %{"developer_session_id" => "other"}),
               cycle(2, "passed")
             ])},
            {"passing Candidate differs",
             verification([cycle(1, "failed"), cycle(2, "passed", %{"candidate_id" => "c1"})])}
          ] do
        objections = if history, do: @objections, else: []
        history = history || verification([cycle(1, "failed"), cycle(2, "passed")])

        assert ReviewPacket.superseded_objection(history, @binding, objections, 0.85) == nil,
               label
      end
    end
  end
end
