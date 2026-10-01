defmodule Kogen.ProgressBudgetTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.Progress

  @config_path Path.expand("../../.kogen/config.yaml", __DIR__)

  defp new(over \\ %{}) do
    {:ok, s} =
      Progress.new(
        Map.merge(
          %{
            max_rounds: 10,
            max_no_progress: 3,
            max_dispatches: 100,
            max_developer_resumptions: 2
          },
          over
        )
      )

    s
  end

  defp round(state, sigs, extra \\ %{}) do
    Progress.record_round(
      state,
      Map.merge(%{tree: "t", signatures: sigs, dispatches: 1, review_no_change: false}, extra)
    )
  end

  test "cleared findings spend a monotonic allowance once per return event" do
    s = new(%{max_no_progress: 2})

    # The baseline is free, and resolving a finding is progress.
    assert {:ok, s} = round(s, ["c", "a", "b", "a"])
    assert s["no_progress"] == 0 and s["rounds"] == 1 and s["dispatches"] == 1
    assert {:ok, s} = round(s, ["b", "c"])
    assert s["no_progress"] == 0

    # A cleared finding returning while another clears is still oscillation.
    assert {:ok, s} = round(s, ["c", "a"])
    assert s["no_progress"] == 1
    assert List.last(s["history"])["no_progress_reason"] == "oscillation"

    # The returned finding persisting while another clears is not charged twice.
    assert {:ok, s} = round(s, ["a"])
    assert s["no_progress"] == 1
    assert List.last(s["history"])["no_progress_reason"] == nil

    # Clearing everything does not refund the spent allowance. A later return
    # is a new event and stops at the frozen limit.
    assert {:ok, s} = round(s, [])
    assert s["unresolved"] == [] and s["no_progress"] == 1
    assert {:stop, :no_progress, d} = round(s, ["a"])
    assert d.ledger.no_progress == 2
    assert d.unresolved == ["a"]
    assert d.last_no_progress_reason == :oscillation
  end

  test "repeated unresolved signatures stop repair only when the frozen allowance is spent" do
    s = new(%{max_no_progress: 2})
    {:ok, s} = round(s, ["a"])
    assert {:ok, s} = round(s, ["a"])
    assert s["no_progress"] == 1 and Progress.remaining(s).no_progress == 1
    assert {:stop, :no_progress, d} = round(s, ["a"])
    assert d.remaining.no_progress == 0
    assert d.ledger.no_progress == 2 and d.unresolved == ["a"]
    assert d.last_no_progress_reason == :nothing_cleared
    assert d.next_action =~ "no-progress"
  end

  test "spent no-progress allowance does not stop once every failure is resolved" do
    {:ok, s} = round(new(%{max_no_progress: 1}), ["a"])
    assert {:ok, s} = round(s, [])
    assert s["unresolved"] == []
  end

  test "progress keeps repair going below the allowance (negative control)" do
    s = new(%{max_no_progress: 2})
    {:ok, s} = round(s, ["a", "b", "c"])
    {:ok, s} = round(s, ["b", "c"])
    {:ok, s} = round(s, ["c"])
    assert {:ok, s} = round(s, ["c", "d"])
    assert s["no_progress"] == 1 and s["unresolved"] == ["c", "d"]
    assert {:ok, s} = round(s, ["d"])
    assert s["no_progress"] == 1
  end

  test "oscillation and same-tree Review no-change rounds spend the allowance and stop" do
    {:ok, s} = round(new(%{max_no_progress: 1}), ["a", "b"])
    {:ok, s} = round(s, ["b"])
    assert {:stop, :no_progress, d} = round(s, ["a"])
    assert d.last_no_progress_reason == :oscillation

    {:ok, s} = round(new(%{max_no_progress: 1}), ["a", "b"])

    assert {:stop, :no_progress, d} = round(s, ["b"], %{review_no_change: true})
    assert d.last_no_progress_reason == :review_no_change
  end

  test "stops at the dispatch limit" do
    s = new(%{max_dispatches: 3})
    {:ok, s} = round(s, ["a", "b"], %{dispatches: 2})
    assert {:stop, :dispatch_limit, d} = round(s, ["b"], %{dispatches: 1})
    assert d.remaining.dispatches == 0
  end

  test "exceeding dispatches stops even when everything resolved" do
    s = new(%{max_dispatches: 2})
    assert {:stop, :dispatch_limit, _} = round(s, [], %{dispatches: 5})
  end

  test "stops at max_rounds while findings remain, not when resolved" do
    s = new(%{max_rounds: 2})
    {:ok, s} = round(s, ["a", "b"])
    assert {:stop, :max_rounds, _} = round(s, ["b"])
    {:ok, s} = round(new(%{max_rounds: 2}), ["a"])
    assert {:ok, _} = round(s, [])
  end

  test "developer resumption limit" do
    s = new(%{max_developer_resumptions: 1})
    assert {:ok, s} = Progress.record_resumption(s)
    assert {:stop, :developer_resumption_limit, d} = Progress.record_resumption(s)
    assert d.ledger.developer_resumptions == 2
    {:ok, s2} = round(new(%{max_developer_resumptions: 1}), ["a"], %{developer_resumption: true})
    assert s2["developer_resumptions"] == 1
  end

  test "each repair handoff charges one Developer resumption and a further one stops" do
    s = new(%{max_developer_resumptions: 2})
    assert {:ok, s} = round(s, ["a"], %{developer_resumption: true})
    assert {:ok, s} = round(s, ["a"], %{developer_resumption: true})
    assert s["developer_resumptions"] == 2

    assert {:stop, :developer_resumption_limit, d} =
             round(s, [], %{developer_resumption: true})

    assert d.remaining.developer_resumptions == 0
    assert d.next_action =~ "resumptions exhausted"
  end

  test "limits are validated and state round-trips through JSON" do
    assert {:error, _} =
             Progress.new(%{
               max_rounds: 0,
               max_no_progress: 1,
               max_dispatches: 1,
               max_developer_resumptions: 1
             })

    assert {:error, _} = Progress.new(%{max_rounds: 1})
    {:ok, s} = round(new(), ["a"])

    assert {:ok, ^s} =
             s |> Progress.to_map() |> Jason.encode!() |> Jason.decode!() |> Progress.from_map()

    assert {:error, _} = Progress.from_map(%{"limits" => %{}})
    assert {:error, _} = Progress.from_map(Map.put(s, "rounds", -1))
    assert {:error, _} = Progress.from_map("x")
  end

  test "new_from_config reads the frozen budget keys" do
    {:ok, config} = Kogen.Intent.read_config(@config_path)
    assert {:ok, s} = Progress.new_from_config(config)
    assert s["limits"]["max_no_progress"] == config.max_no_progress
  end
end
