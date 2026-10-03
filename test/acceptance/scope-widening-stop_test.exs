defmodule Kogen.Acceptance.ScopeWideningStopTest do
  use Kogen.Testkit.Case

  alias Kogen.Build.Cycle
  alias Kogen.Contracts.Failure

  @moduletag :acceptance
  @detail "Out-of-scope paths changed: lib/outside.ex"

  @tag intent: "scope-widening-stop/A1"
  test "a repeated identical scope edit stops for widening" do
    state = developing()
    {state, _effects} = Cycle.step(state, scope_failure(@detail))
    assert state.stage == :develop

    {state, _effects} = Cycle.step(state, scope_failure(@detail))

    assert {:failed, reason} = state.result
    assert inspect(reason) =~ "scope_needs_widening"
    assert inspect(reason) =~ "lib/outside.ex"
  end

  @tag intent: "scope-widening-stop/A2"
  test "a different scope edit still gets a repair" do
    state = developing()
    {state, _effects} = Cycle.step(state, scope_failure(@detail))

    {state, _effects} =
      Cycle.step(state, scope_failure("Out-of-scope paths changed: lib/other.ex"))

    assert state.result == nil
    assert state.stage == :develop
    assert state.repairs_left == 0
  end

  @tag intent: "scope-widening-stop/A3"
  test "a first scope edit gets a repair" do
    {state, _effects} = Cycle.step(developing(), scope_failure(@detail))

    assert state.result == nil
    assert state.stage == :develop
    assert state.repairs_left == 1
  end

  defp developing do
    state = Cycle.new(%{approval: %{slug: "probe"}, repairs: 2})
    {state, _effects} = Cycle.step(state, {:stage_ok, :context, %{}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :plan, %{}})
    state
  end

  defp scope_failure(detail) do
    {:stage_failed, :develop, %Failure{class: :candidate, reason: :scope_edit, detail: detail}}
  end
end
