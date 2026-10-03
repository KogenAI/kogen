defmodule Kogen.Acceptance.GateFlakeAdvanceTest do
  use Kogen.Testkit.Case

  alias Kogen.Build.Cycle
  alias Kogen.Contracts.Failure

  @moduletag :acceptance

  @tag intent: "gate-flake-advance/A1"
  test "an unchanged tree after a done-gate repair returns to the gate" do
    state = red_gate_once()

    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})
    assert state.stage == :done_gate
    assert state.result == nil

    {state, _effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :done}})
    assert state.stage == :fix
  end

  @tag intent: "gate-flake-advance/A2"
  test "repeated red gates on an unchanged tree stop at the repair cap" do
    state = red_gate_once()

    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :gate_red}})
    assert state.repairs_left == 0

    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :gate_red}})
    assert {:failed, reason} = state.result
    assert inspect(reason) =~ "repair_cap"
  end

  @tag intent: "gate-flake-advance/A3"
  test "an unchanged tree after a red check repair still fails" do
    state = started()
    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :done}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :fix, %{}})

    failure = %Failure{class: :candidate, reason: :red, detail: "tail"}
    {state, _effects} = Cycle.step(state, {:stage_failed, :check, failure})
    assert state.stage == :develop

    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})
    assert {:failed, reason} = state.result
    assert inspect(reason) =~ "unchanged"
  end

  defp started do
    state = Cycle.new(%{approval: %{slug: "probe"}, repairs: 2})
    {state, _effects} = Cycle.step(state, {:stage_ok, :context, %{}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :plan, %{}})
    state
  end

  defp red_gate_once do
    state = started()
    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :gate_red}})
    assert state.stage == :develop
    assert state.repairs_left == 1
    state
  end
end
