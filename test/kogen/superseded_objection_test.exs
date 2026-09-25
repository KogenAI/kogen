Code.require_file("../support/scripted_build_fixture.ex", __DIR__)

defmodule Kogen.SupersededObjectionTest do
  @moduledoc """
  A confident Developer objection written before Stop verification of the same
  attempt passed is superseded: it no longer stops the Build, it is recorded on
  the attempt and it reaches the fresh Reviewer as a labelled advisory item in
  the review packet. Every other confident objection stops as cannot-comply.
  The Build route tests drive the real `settle_outcome` with fake Stop cycles
  and a stubbed Jev transport.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.ReviewPacket
  alias Kogen.FakeJev
  alias Kogen.ScriptedBuildFixture, as: Fixture

  @prefix "Developer cannot comply as approved; return to Shaping:"
  @objection "I object: s-change cannot be met as approved; it needs a path outside the guarded list."
  @answers %{"objection:scenario:s-change" => ["objection", 0.95]}

  test "failed-then-passed Stop cycles in one attempt supersede the objection and reach Review" do
    dir = Fixture.fixture!()

    assert :ok =
             Fixture.run(dir,
               notes: [@objection],
               fail_first: [1],
               jev_answers: @answers,
               edits: %{1 => "printf 'changed\\n' > dummy.txt"}
             )

    assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "1"
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

    # The Reviewer's packet carries it as a labelled advisory item.
    packet = Jason.decode!(File.read!(Path.join(dir, ".kogen/runtime/reviewer-packet-1.json")))
    assert packet["superseded_objection"]["label"] =~ "advisory"
    assert packet["superseded_objection"]["label"] =~ "Judge every scenario yourself"

    assert Map.delete(packet["superseded_objection"], "label") == superseded
    assert packet["developer_notes"] == @objection

    assert Fixture.reviewer_prompt!(dir, 1) =~ "superseded_objection"
  end

  test "a single passing Stop cycle keeps an objection a cannot-comply stop" do
    dir = Fixture.fixture!()

    assert {:error, reason} = Fixture.run(dir, notes: [@objection], jev_answers: @answers)

    assert String.starts_with?(reason, @prefix)
    assert reason =~ "scenario `s-change` (Jev confidence 0.95)"
    assert reason =~ "Developer's notes: \"#{@objection}\""
    refute File.exists?(Path.join(dir, ".kogen/runtime/reviews"))
    [attempt] = Fixture.record!(dir)["attempts"]
    assert attempt["outcome"] == "cannot_comply"
    refute Map.has_key?(attempt, "superseded_objection")
    refute Map.has_key?(attempt, "review_packet")
  end

  test "exhausted verification with an objection never reaches Review" do
    dir = Fixture.fixture!()

    assert {:error, reason} =
             Fixture.run(dir, notes: [@objection], fail_all: [1], jev_answers: @answers)

    assert String.starts_with?(reason, @prefix)
    assert reason =~ "verification retries exhausted"
    refute File.exists?(Path.join(dir, ".kogen/runtime/reviews"))
    [attempt] = Fixture.record!(dir)["attempts"]
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
               jev_results: [
                 {200, FakeJev.answer_body(items)},
                 {200,
                  FakeJev.answer_body(Fixture.jev_items(["F1"]), %{
                    "objection:scenario:s-change" => {"objection", 0.95}
                  })}
               ]
             )

    assert String.starts_with?(reason, @prefix)
    assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "1"
    [first, second] = Fixture.record!(dir)["attempts"]
    assert Enum.map(first["verification"]["cycles"], & &1["status"]) == ["failed", "passed"]
    assert Enum.map(second["verification"]["cycles"], & &1["status"]) == ["passed"]
    assert second["outcome"] == "cannot_comply"
    refute Map.has_key?(second, "superseded_objection")
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
    packet = Jason.decode!(File.read!(Path.join(dir, ".kogen/runtime/reviewer-packet-1.json")))
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
