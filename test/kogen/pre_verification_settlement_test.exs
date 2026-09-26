Code.require_file("../support/scripted_build_fixture.ex", __DIR__)

defmodule Kogen.PreVerificationSettlementTest do
  @moduledoc """
  Scenario `notes-and-selectors-before-verification`: at 7ed41f66,
  `verify_turn/5` ran `Verification.run_cycle` first, so a first-turn
  objection or a missing declared proof selector still spent a `check` (and,
  eventually, a paid) verification cycle before it was ever read. Now,
  before any verification cycle: Jev reads the turn's notes once, an
  objection with no earlier failed cycle in the attempt stops the Build as
  `cannot_comply` without running any target; a missing declared proof
  selector returns the Developer as `unfinished_work` without running a
  cycle either. Only then does the cycle run.

  Driven through a fake-harness Build (`Kogen.ScriptedBuildFixture`, an
  offline-only `check` target and the offline fake Jev) via the real
  `Kogen.Build.run/1` consumer, with Make counters read from the retained
  verification logs.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.FakeJev
  alias Kogen.ScriptedBuildFixture, as: Fixture

  test "an objection on the first turn stops as cannot-comply, with no check run and nothing dispatched" do
    dir = Fixture.fixture!()

    assert {:error, reason} =
             Fixture.run(dir,
               notes: ["I object: fix3 is unreachable, return to Shaping."],
               jev_answers: %{"objection:scenario:s-change" => ["objection", 0.95]}
             )

    assert String.starts_with?(reason, "Developer cannot comply as approved; return to Shaping:")
    assert reason =~ "I object: fix3 is unreachable"

    # No verification cycle ran: no `check` log was ever retained, and the
    # attempt's own execution state carries no cycle.
    logs =
      Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*/verification/*/logs/*"))

    assert logs == []

    [state_path] =
      Path.wildcard(
        Path.join(dir, ".kogen/runtime/scenario-tracking/*/verification/*/state.json")
      )

    state = state_path |> File.read!() |> Jason.decode!()
    assert state["cycles"] == []

    tracking = Fixture.record!(dir)
    [attempt] = tracking["attempts"]
    refute Map.has_key?(attempt, "verification")

    # Jev was asked exactly once, before the (never-run) cycle.
    assert length(FakeJev.requests(Path.join(dir, ".kogen/runtime/fake-jev"))) == 1
  end

  test "a missing declared proof selector is unfinished work with no cycle run; the next turn verifies and passes once it exists" do
    dir = Fixture.fixture!(late_selector: true)
    late_selector = Fixture.late_selector()

    # Turn 1: the Developer says nothing is unfinished, but the declared
    # `s-late` proof selector does not exist yet.
    # Turn 2 (a fresh outer attempt, `rework`'s resumption): the Developer
    # creates it.
    assert :ok =
             Fixture.run(dir,
               edits: %{
                 2 =>
                   "mkdir -p $(dirname #{late_selector}) && printf '# late selector\\n' > #{late_selector}"
               },
               reviews: "accept"
             )

    tracking = Fixture.record!(dir)
    [first, second] = tracking["attempts"]

    assert first["outcome"] == "unfinished_work"
    assert first["unfinished_work"]["missing_selectors"] == [late_selector]
    refute Map.has_key?(first, "verification")

    # The first attempt's own verification execution never ran a cycle.
    [first_state_path] =
      Path.wildcard(
        Path.join(dir, ".kogen/runtime/scenario-tracking/*/verification/attempt-0-*/state.json")
      )

    first_state = first_state_path |> File.read!() |> Jason.decode!()
    assert first_state["cycles"] == []

    # The second attempt (after the selector was created) verifies normally.
    assert Enum.map(second["verification"]["cycles"], & &1["status"]) == ["passed"]
  end

  test "with no objection and every declared selector present, the turn is verified exactly as today, with one Jev call for the turn" do
    dir = Fixture.fixture!()

    assert :ok = Fixture.run(dir, reviews: "accept")

    tracking = Fixture.record!(dir)
    [attempt] = tracking["attempts"]
    assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) == ["passed"]
    assert length(FakeJev.requests(Path.join(dir, ".kogen/runtime/fake-jev"))) == 1
  end
end
