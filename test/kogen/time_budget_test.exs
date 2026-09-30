defmodule Kogen.TimeBudgetTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.{DispatchLedger, Progress}

  @limits %{
    max_rounds: 10,
    max_no_progress: 3,
    max_dispatches: 100,
    max_developer_resumptions: 5,
    build_time_nudge_minutes: 60
  }

  defp new(over \\ %{}) do
    {:ok, s} = Progress.new(Map.merge(@limits, over))
    s
  end

  test "elapsed time is measured per Build and per phase, and only grows" do
    s = new()
    assert s["limits"]["build_time_nudge_minutes"] == 60

    s =
      s
      |> Progress.charge(10 * 60_000, "verification")
      |> Progress.charge(-5)
      |> Progress.charge(2 * 60_000, "verification")
      |> Progress.charge(1_000, "repair handoff")

    assert s["elapsed_ms"] == 12 * 60_000 + 1_000
    assert s["phases"] == %{"verification" => 12 * 60_000, "repair handoff" => 1_000}
    refute Map.has_key?(Progress.remaining(s), :time_ms)
  end

  test "cycle durations are recorded and summarised" do
    s = new() |> Progress.observe(turn_ms: 5, cycle_ms: 6) |> Progress.observe(cycle_ms: 7)
    assert s["last_turn_ms"] == 5 and s["last_cycle_ms"] == 7 and s["cycles_ms"] == [6, 7]
    assert %{"cycles_ms" => [6, 7], "nudge_minutes" => 60} = Progress.time_summary(s)
  end

  test "no stop, refusal or cancellation exists for elapsed time" do
    refute function_exported?(Progress, :check_time, 2)
    refute function_exported?(Progress, :repair_need_ms, 1)
    refute function_exported?(Progress, :time_remaining_ms, 1)

    # Two hours of active time, far past the nudge: still no stop from any
    # progress operation.
    s = new() |> Progress.charge(120 * 60_000, "verification")
    assert {:ok, s} = Progress.record_round(s, %{tree: "t", signatures: ["a"], dispatches: 1})
    assert {:ok, _} = Progress.record_resumption(s)

    lib = File.read!(Path.expand("../../lib/kogen/build.ex", __DIR__))
    verification = File.read!(Path.expand("../../lib/kogen/build/verification.ex", __DIR__))
    refute lib =~ "time_budget"
    refute verification =~ "time_budget"
    refute verification =~ "deadline_ms"
  end

  test "passing the nudge is due exactly once, and is a warning only" do
    s = new(%{build_time_nudge_minutes: 60})
    refute Progress.nudge_due?(s)
    refute Progress.past_nudge?(s)

    s = Progress.charge(s, 61 * 60_000, "verification")
    assert Progress.nudge_due?(s)
    assert Progress.past_nudge?(s)

    s = Progress.mark_nudged(s)
    refute Progress.nudge_due?(s)
    assert Progress.past_nudge?(s)
    assert Progress.time_summary(s)["nudged"] == true
  end

  test "no nudge configured means no warning, and old states stay readable" do
    {:ok, s} = Progress.new(Map.delete(@limits, :build_time_nudge_minutes))
    s = Progress.charge(s, 1_000 * 60_000)
    refute Progress.nudge_due?(s)
    refute Progress.past_nudge?(s)

    old =
      Map.drop(s, ~w(elapsed_ms last_turn_ms last_cycle_ms phases cycles_ms nudged turn_nudges))

    assert {:ok, read} = Progress.from_map(old)
    assert read["elapsed_ms"] == 0 and read["phases"] == %{} and read["turn_nudges"] == []

    legacy = put_in(s, ["limits", "build_time_budget_minutes"], 60)
    assert {:ok, _} = Progress.from_map(legacy)
  end

  test "Developer turn nudges are recorded and never charged as resumptions" do
    s = new()

    s =
      s
      |> Progress.record_turn_nudge(%{"nudge" => 1, "turn_minutes" => 30})
      |> Progress.record_turn_nudge(%{"nudge" => 2, "turn_minutes" => 60})

    assert [%{"nudge" => 1}, %{"nudge" => 2}] = s["turn_nudges"]
    assert s["developer_resumptions"] == 0
  end

  test "state with time fields round-trips through JSON" do
    s =
      new()
      |> Progress.charge(1234, "verification")
      |> Progress.observe(turn_ms: 5, cycle_ms: 6)
      |> Progress.record_turn_nudge(%{"nudge" => 1})

    assert {:ok, ^s} =
             s |> Progress.to_map() |> Jason.encode!() |> Jason.decode!() |> Progress.from_map()

    assert {:error, _} = Progress.new(Map.put(@limits, :build_time_nudge_minutes, 0))
  end

  test "the frozen config carries build_time_nudge_minutes and developer_turn_minutes" do
    path = Path.expand("../../.kogen/config.yaml", __DIR__)
    {:ok, config} = Kogen.Intent.read_config(path)
    assert is_integer(config.build_time_nudge_minutes) and config.build_time_nudge_minutes > 0
    assert is_integer(config.developer_turn_minutes) and config.developer_turn_minutes > 0
    refute Map.has_key?(config, :build_time_budget_minutes)
    assert {:ok, s} = Progress.new_from_config(config)
    assert s["limits"]["build_time_nudge_minutes"] == config.build_time_nudge_minutes
  end

  test "the provisional Reviewer dispatch is one ledger entry, recorded once" do
    cycles = [%{"sequence" => 1, "candidate_id" => "t1"}]

    review = %{
      "target" => "provisional-review",
      "role" => "reviewer",
      "candidate_id" => "t1",
      "cycle" => 1,
      "attempt" => "initial",
      "pid" => nil,
      "process_started_at" => nil,
      "started_at" => "2026-01-01T00:00:00.000Z",
      "outcome" => "exited"
    }

    ledger = DispatchLedger.append([], [review])
    assert DispatchLedger.count(ledger) == 1
    assert DispatchLedger.append(ledger, [review]) == ledger
    assert DispatchLedger.validate(ledger, cycles) == :ok

    # A non-reviewer entry still needs a registered process identity.
    assert {:error, _} =
             DispatchLedger.validate(
               DispatchLedger.append([], [Map.delete(review, "role")]),
               cycles
             )
  end

  test "a flaky round counts as no progress" do
    {:ok, s} = Progress.record_round(new(), %{tree: "t", signatures: ["a", "b"], dispatches: 1})

    assert {:ok, s} =
             Progress.record_round(s, %{tree: "t", signatures: ["b"], dispatches: 1, flaky: true})

    assert s["no_progress"] == 1
    assert List.last(s["history"])["no_progress_reason"] == "flaky"
  end

  test "live_concurrency is a finite configured ceiling" do
    path = Path.expand("../../.kogen/config.yaml", __DIR__)
    {:ok, config} = Kogen.Intent.read_config(path)
    assert config.live_concurrency == 4
  end
end
