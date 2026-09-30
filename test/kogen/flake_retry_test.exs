Code.require_file("../support/verification_cycle_fixture.ex", __DIR__)

defmodule Kogen.FlakeRetryTest do
  @moduledoc """
  One same-tree rerun of a failed live target (`same_tree_retry: 1` in the
  catalog): recorded as two attempts, marked `flaky` on a pass, capped at one
  per target per Build, costing a dispatch but no round, and never for a
  target without the flag or when no dispatch is left.
  """

  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.Verification
  alias Kogen.VerificationCycleFixture, as: Fixture

  @retries 2

  setup do
    root = Fixture.new!()
    scratch = root <> "-scratch"
    File.mkdir_p!(scratch)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(scratch)
    end)

    {:ok, root: root, scratch: scratch}
  end

  defp install!(root, recipes, retry \\ 1) do
    names = ["check" | Enum.map(recipes, &elem(&1, 0))]

    entries =
      [Fixture.offline_entry("check")] ++
        (recipes
         |> Enum.with_index()
         |> Enum.map(fn {{name, _}, index} ->
           entry = Fixture.provider_entry(name, 100 + index * 100)
           if retry, do: Map.put(entry, "same_tree_retry", retry), else: entry
         end))

    Fixture.write_catalog!(root, entries)

    makefile =
      ".PHONY: #{Enum.join(names, " ")}\n\ncheck:\n\t@true\n" <>
        Enum.map_join(recipes, fn {name, recipe} -> "\n#{name}:\n\t#{recipe}\n" end)

    File.write!(Path.join(root, "Makefile"), makefile)
    plan = Fixture.plan(root, names)
    {plan, Fixture.env(root, plan)}
  end

  defp start!(root, plan) do
    {:ok, execution} =
      Verification.initialize(
        Fixture.tracking_path(root),
        "token-1",
        0,
        plan.targets,
        %{verification: @retries, offline: 1},
        plan,
        nil
      )

    execution
  end

  defp cycle!(root, execution, env) do
    candidate = Fixture.candidate_id!(root)
    {:ok, execution, state} = Fixture.run_cycle(execution, "session-1", candidate, env)
    {execution, state, List.last(state["cycles"])}
  end

  defp receipt(cycle, target), do: Enum.find(cycle["receipts"], &(&1["target"] == target))

  defp flaky_recipe(scratch),
    do:
      ~s(@if [ -e #{scratch}/seen ]; then echo second-ok; else : > #{scratch}/seen; echo first-boom; exit 1; fi)

  test "a pass on the same-tree retry is flaky, records both attempts and costs one dispatch",
       %{root: root, scratch: scratch} do
    {plan, env} = install!(root, [{"p1", flaky_recipe(scratch)}])
    execution = start!(root, plan)
    {execution, state, cycle} = cycle!(root, execution, env)

    assert cycle["status"] == "passed", inspect(cycle["failures"])
    receipt = receipt(cycle, "p1")
    assert receipt["status"] == "passed"
    assert receipt["flaky"] == true
    assert [%{"attempt" => "initial", "status" => "failed"}, retry] = receipt["attempts"]
    assert %{"attempt" => "same-tree-retry", "status" => "passed"} = retry
    assert Enum.all?(receipt["attempts"], &File.exists?(Path.join(root, &1["log_path"])))
    assert cycle["flaky"] == ["p1"]

    assert Enum.map(state["dispatch_ledger"], &{&1["target"], &1["attempt"]}) ==
             [{"p1", "initial"}, {"p1", "same-tree-retry"}]

    assert cycle["dispatch_count"] == 2
    assert Verification.validate_state(state, execution) == :ok
  end

  test "a target that fails both attempts fails once, keeps both logs and retries once per Build",
       %{root: root} do
    {plan, env} = install!(root, [{"p1", "@echo always-boom; exit 1"}])
    execution = start!(root, plan)
    {execution, state, cycle} = cycle!(root, execution, env)

    assert cycle["status"] == "failed"
    assert cycle["failure"]["target"] == "p1"
    assert cycle["failure"]["class"] == "paid"
    assert cycle["failure"]["same_tree_retry"] == true

    assert [%{"attempt" => "initial"}, %{"attempt" => "same-tree-retry"}] =
             cycle["failure"]["attempts"]

    assert cycle["dispatch_count"] == 2
    refute Map.has_key?(cycle, "flaky")
    assert Verification.validate_state(state, execution) == :ok

    # The cap is per Build: a later cycle dispatches p1 once and does not retry.
    {_execution, state2, cycle2} = cycle!(root, execution, env)
    assert cycle2["dispatch_count"] == 1
    assert state2["dispatch_count"] == 3
    assert Enum.count(state2["dispatch_ledger"], &(&1["attempt"] == "same-tree-retry")) == 1
  end

  test "a login rejection on the retry attempt is environment, not a paid retry failure",
       %{root: root, scratch: scratch} do
    tail =
      Path.expand("../support/provider_tails/xfjcrm76_claude_oauth_revoked.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("output")

    File.write!(Path.join(scratch, "tail.txt"), tail)

    recipe =
      ~s(@if [ -e #{scratch}/seen ]; then cat #{scratch}/tail.txt; else : > #{scratch}/seen; echo first-boom; fi; exit 1)

    {plan, env} = install!(root, [{"p1", recipe}])
    execution = start!(root, plan)
    {_execution, _state, cycle} = cycle!(root, execution, env)

    assert cycle["status"] == "failed"
    assert cycle["failure"]["class"] == "environment"
    assert cycle["failure"]["reason"] =~ "login rejected (401)"
    assert cycle["dispatch_count"] == 2
  end

  test "a target without the flag is never retried", %{root: root} do
    {plan, env} = install!(root, [{"p1", "@echo boom; exit 1"}], nil)
    execution = start!(root, plan)
    {_execution, _state, cycle} = cycle!(root, execution, env)

    assert cycle["status"] == "failed"
    assert cycle["dispatch_count"] == 1
    refute Map.has_key?(receipt(cycle, "p1"), "attempts")
  end

  test "no retry when the dispatch budget has nothing left after the planned dispatches",
       %{root: root} do
    {plan, env} = install!(root, [{"p1", "@echo boom; exit 1"}])
    execution = start!(root, plan)
    {_execution, _state, cycle} = cycle!(root, execution, Map.put(env, :dispatches_left, 1))

    assert cycle["status"] == "failed"
    assert cycle["dispatch_count"] == 1
    refute Map.has_key?(receipt(cycle, "p1"), "attempts")
  end

  test "the last available dispatch may be spent on the same-tree retry (zero remainder)",
       %{root: root, scratch: scratch} do
    {plan, env} = install!(root, [{"p1", flaky_recipe(scratch)}])
    execution = start!(root, plan)
    {_execution, _state, cycle} = cycle!(root, execution, Map.put(env, :dispatches_left, 2))

    assert cycle["status"] == "passed", inspect(cycle["failures"])
    assert cycle["dispatch_count"] == 2
    assert receipt(cycle, "p1")["flaky"] == true
  end

  test "a failing sibling is never cancelled by a retrying target", %{
    root: root,
    scratch: scratch
  } do
    {plan, env} =
      install!(root, [{"p1", flaky_recipe(scratch)}, {"p2", "@echo slow-ok; sleep 1"}])

    execution = start!(root, plan)
    {_execution, _state, cycle} = cycle!(root, execution, env)

    assert cycle["status"] == "passed", inspect(cycle["failures"])
    assert receipt(cycle, "p2")["status"] == "passed"
    assert receipt(cycle, "p1")["flaky"] == true
  end
end
