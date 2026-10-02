defmodule Kogen.Build.CycleTest do
  use Kogen.Testkit.Case

  alias Kogen.Build.Cycle
  alias Kogen.Contracts.Failure

  test "transition table covers every stage and failure transition" do
    rows = transition_rows()

    assert length(rows) >= 25

    Enum.each(rows, fn {name, state, event, expected_stage, repairs_left, effect_kind} ->
      {next, effects} = Cycle.step(state, event)

      assert next.stage == expected_stage, name
      assert next.repairs_left == repairs_left, name
      assert effect_kind(effects) == effect_kind, name
    end)
  end

  test "landing identity is recorded before the land effect" do
    state = state_at(:land)
    {next, effects} = Cycle.step(state, {:stage_ok, :commit, landing_data()})

    assert next.pending_land

    assert [{:record, %{event: :landing_prepared, landing: identity}}, {:run, :land, identity}] =
             effects

    assert identity.run_id == "run-1"
    assert identity.candidate_commit == "candidate"
  end

  test "the cycle stays pure across a complete successful path" do
    state = Cycle.new(%{approval: %{slug: "sample"}, repairs: 2})

    {state, _} = Cycle.step(state, {:stage_ok, :context, %{}})
    {state, _} = Cycle.step(state, {:stage_ok, :plan, %{}})
    {state, _} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})
    {state, _} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :done}})
    {state, _} = Cycle.step(state, {:stage_ok, :fix, %{}})
    {state, _} = Cycle.step(state, {:stage_ok, :check, %{status: :pass}})
    {state, _} = Cycle.step(state, {:review, :accept, []})
    {state, _} = Cycle.step(state, {:stage_ok, :commit, landing_data()})
    {state, effects} = Cycle.step(state, {:landed, "candidate"})

    assert state.stage == :landed
    assert state.result == {:landed, "candidate"}
    assert [{:record, %{event: :finished}}, {:finish, :landed, "candidate"}] = effects
  end

  defp state_at(stage, overrides \\ []) do
    state = Cycle.new(%{approval: %{slug: "sample"}, repairs: 2})
    struct!(state, Keyword.put(overrides, :stage, stage))
  end

  defp failure(class, reason), do: %Failure{class: class, reason: reason, detail: "tail"}

  defp landing_data do
    %{
      approval_commit: "approval",
      run_id: "run-1",
      expected_parent: "parent",
      final_tree: "tree-1",
      candidate_commit: "candidate"
    }
  end

  defp transition_rows, do: pipeline_rows() ++ repair_rows() ++ terminal_rows()

  defp pipeline_rows do
    [
      {"context succeeds", state_at(:context), {:stage_ok, :context, %{}}, :plan, 2, :plan_run},
      {"plan succeeds", state_at(:plan), {:stage_ok, :plan, %{}}, :develop, 2, :develop_run},
      {"developer succeeds", state_at(:develop), {:stage_ok, :develop, %{tree: "tree-1"}},
       :done_gate, 2, :record},
      {"done gate passes", state_at(:done_gate), {:stage_ok, :done_gate, %{outcome: :done}}, :fix,
       2, :fix_run},
      {"fix succeeds", state_at(:fix), {:stage_ok, :fix, %{}}, :check, 2, :check_run},
      {"checks pass", state_at(:check), {:stage_ok, :check, %{status: :pass}}, :review, 2,
       :review_run},
      {"review accepts", state_at(:review), {:review, :accept, []}, :land, 2, :commit_run},
      {"commit records identity", state_at(:land), {:stage_ok, :commit, landing_data()}, :land, 2,
       :land_run},
      {"landing succeeds", state_at(:land, pending_land: true), {:landed, "candidate"}, :landed,
       2, :finish_landed}
    ]
  end

  defp repair_rows do
    [
      {"done gate red repairs", state_at(:done_gate),
       {:stage_ok, :done_gate, %{outcome: :gate_red}}, :develop, 1, :develop_run},
      {"review revises", state_at(:review), {:review, :revise, ["A1"]}, :develop, 1,
       :develop_run},
      {"review revise reaches cap", state_at(:review, repairs_left: 0), {:review, :revise, []},
       :failed, 0, :finish_failed},
      {"candidate check red repairs", state_at(:check, last_tree: "tree-1"),
       {:stage_failed, :check, failure(:candidate, :red)}, :develop, 1, :develop_run},
      {"candidate review failure repairs", state_at(:review, last_tree: "tree-1"),
       {:stage_failed, :review, failure(:candidate, :review_red)}, :develop, 1, :develop_run},
      {"landing conflict repairs", state_at(:land, pending_land: true, last_tree: "tree-1"),
       {:stage_failed, :land, failure(:candidate, :conflict)}, :develop, 1, :develop_run},
      {"candidate red at cap fails", state_at(:check, repairs_left: 0),
       {:stage_failed, :check, failure(:candidate, :red)}, :failed, 0, :finish_failed},
      {"unchanged repaired tree fails",
       state_at(:develop, repair_tree: "tree-1", repairs_left: 1),
       {:stage_ok, :develop, %{tree: "tree-1"}}, :failed, 1, :finish_failed},
      {"changed repaired tree advances",
       state_at(:develop, repair_tree: "tree-1", repairs_left: 1),
       {:stage_ok, :develop, %{tree: "tree-2"}}, :done_gate, 1, :record}
    ]
  end

  defp terminal_rows do
    [
      {"missing commit identity fails", state_at(:land), {:stage_ok, :commit, %{}}, :failed, 2,
       :finish_failed},
      {"land stage cannot skip identity", state_at(:land),
       {:stage_ok, :land, %{sha: "candidate"}}, :failed, 2, :finish_failed},
      {"land stage succeeds after receipt", state_at(:land, pending_land: true),
       {:stage_ok, :land, %{sha: "candidate"}}, :landed, 2, :finish_landed},
      {"base moved parks", state_at(:land, pending_land: true), {:base_moved}, :parked, 2,
       :finish_parked},
      {"environment failure stops", state_at(:check),
       {:stage_failed, :check, failure(:environment, :missing_tool)}, :failed, 2, :finish_failed},
      {"provider retry one", state_at(:check),
       {:stage_failed, :check, failure(:provider, :overload)}, :check, 2, :check_run},
      {"provider retry two", state_at(:check, provider_retries: 1),
       {:stage_failed, :check, failure(:provider, :timeout)}, :check, 2, :check_run},
      {"provider cap stops", state_at(:check, provider_retries: 2),
       {:stage_failed, :check, failure(:provider, :overload)}, :failed, 2, :finish_failed},
      {"controller failure stops", state_at(:develop),
       {:stage_failed, :develop, failure(:controller, :bug)}, :failed, 2, :finish_failed},
      {"wrong stage event fails", state_at(:check), {:stage_ok, :develop, %{}}, :failed, 2,
       :finish_failed},
      {"unknown event fails", state_at(:context), :unknown, :failed, 2, :finish_failed},
      {"terminal state ignores events", state_at(:landed, result: {:landed, "candidate"}),
       {:base_moved}, :landed, 2, :empty}
    ]
  end

  defp effect_kind([]), do: :empty
  defp effect_kind([{:finish, :failed, _reason} | _rest]), do: :finish_failed
  defp effect_kind([{:finish, :landed, _reason} | _rest]), do: :finish_landed
  defp effect_kind([{:finish, :parked, _reason} | _rest]), do: :finish_parked
  defp effect_kind([{:record, %{event: :landing_prepared}}, {:run, :land, _args}]), do: :land_run
  defp effect_kind([{:record, _record} | rest]) when rest != [], do: effect_kind(rest)
  defp effect_kind([{:run, :plan, _args} | _rest]), do: :plan_run
  defp effect_kind([{:run, :develop, _args} | _rest]), do: :develop_run
  defp effect_kind([{:run, :fix, _args} | _rest]), do: :fix_run
  defp effect_kind([{:run, :check, _args} | _rest]), do: :check_run
  defp effect_kind([{:run, :review, _args} | _rest]), do: :review_run
  defp effect_kind([{:run, :commit, _args} | _rest]), do: :commit_run
  defp effect_kind([{:record, _record} | _rest]), do: :record
end
