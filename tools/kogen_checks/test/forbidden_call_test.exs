defmodule KogenChecks.Check.ForbiddenCallTest do
  use Credo.Test.Case

  alias KogenChecks.Check.ForbiddenCall

  @rules [
    rules: [
      %{
        calls: [{File, :cd!}, {File, :cd}, {System, :put_env}, {Application, :put_env}],
        message: "Pass ctx.root/ctx.env instead.",
        allow: []
      },
      %{
        calls: [{Process, :sleep}, {:timer, :sleep}],
        message: "Wait on a message or the injected clock.",
        allow: []
      },
      %{
        calls: [{System, :cmd}, {Port, :open}, {:os, :cmd}],
        message: "Spawn through the Proc port (deadline, group kill).",
        allow: ["lib/kogen/proc/"]
      },
      %{
        calls: [{System, :get_env}, {File, :cwd!}, {DateTime, :utc_now}],
        message: "Read from ctx.",
        allow: ["lib/kogen/kernel/ctx_builder.ex"]
      }
    ]
  ]

  test "flags direct calls, erlang calls, captures and imports" do
    """
    defmodule Kogen.Build.X do
      import File
      def a, do: File.cd!("/tmp")
      def b, do: :timer.sleep(10)
      def c, do: Enum.map([1], &Process.sleep/1)
      def d, do: System.cmd("git", ["status"])
    end
    """
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(ForbiddenCall, @rules)
    |> assert_issues(fn issues ->
      assert Enum.map(issues, & &1.trigger) ==
               ["import File", "File.cd!", ":timer.sleep", "Process.sleep", "System.cmd"]

      assert hd(tl(issues)).message =~ "Pass ctx.root"
    end)
  end

  test "allows a call inside its allowed path" do
    "defmodule Kogen.Proc.Run do\n  def r, do: System.cmd(\"x\", [])\nend\n"
    |> to_source_file("lib/kogen/proc/run.ex")
    |> run_check(ForbiddenCall, @rules)
    |> refute_issues()
  end

  test "ignores lookalikes" do
    "defmodule A do\n  def r(x), do: x.sleep(1) && MyFile.cd!(1) && File.read!(\"a\")\nend\n"
    |> to_source_file("lib/kogen/build/a.ex")
    |> run_check(ForbiddenCall, @rules)
    |> refute_issues()
  end

  test "survives __MODULE__-relative aliases (crashed on develop corpus)" do
    "defmodule A do\n  def r, do: __MODULE__.State.x() && %__MODULE__.S{}\nend\n"
    |> to_source_file("lib/kogen/build/a.ex")
    |> run_check(ForbiddenCall, @rules)
    |> refute_issues()
  end
end
