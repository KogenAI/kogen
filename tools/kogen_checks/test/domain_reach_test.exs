defmodule KogenChecks.Check.DomainReachTest do
  use Credo.Test.Case

  alias KogenChecks.Check.DomainReach

  test "flags a call into another domain, allows own + contracts" do
    """
    defmodule Kogen.Build.Cycle do
      alias Kogen.Contracts.Effect
      alias Kogen.Build.State
      def step(s), do: Kogen.Checks.Runner.run(s) && %Effect{} && State.x()
    end
    """
    |> to_source_file("lib/kogen/build/cycle.ex")
    |> run_check(DomainReach)
    |> assert_issue(fn i -> assert i.trigger == "Kogen.Checks.Runner" end)
  end

  test "tests are scoped to their domain too; kernel exempt" do
    "defmodule Kogen.Build.CycleTest do\n  def t, do: Kogen.Workspace.Git.x()\nend\n"
    |> to_source_file("test/build/cycle_test.exs")
    |> run_check(DomainReach, also_allowed: [Kogen.Testkit])
    |> assert_issue()

    "defmodule Kogen.Kernel.Wiring do\n  def w, do: Kogen.Workspace.Git.x()\nend\n"
    |> to_source_file("lib/kogen/kernel/wiring.ex")
    |> run_check(DomainReach)
    |> refute_issues()
  end
end
