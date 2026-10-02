defmodule KogenChecks.Check.CtxBagTest do
  use Credo.Test.Case

  alias KogenChecks.Check.CtxBag

  test "flags ctx and context parameter names" do
    """
    defmodule X do
      def run(ctx), do: ctx.root
      defp next(_value, context), do: context.env
    end
    """
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(CtxBag)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.trigger) |> Enum.sort() == ["context", "ctx"]
    end)
  end

  test "flags a structurally threaded bag with ambient fields" do
    """
    defmodule X do
      def a(env), do: b(env, env.root)
      def b(env, value), do: c(env, value, env.clock)
      def c(env, value, clock), do: d(env, value, clock, env.runner)
      def d(env, value, clock, runner), do: {value, clock, runner, env.tmp, env.io, env.git, env.control, env.state, env.logs, env[:limits], Map.get(env, :tracking)}
    end
    """
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(CtxBag)
    |> assert_issue(fn issue -> assert issue.message =~ "threaded like a context bag" end)
  end

  test "allows plain values and struct typed records" do
    """
    defmodule X do
      def a(root, now), do: {b(root), c(now)}
      defp b(root), do: Path.join(root, "x")
      defp c(now), do: DateTime.to_iso8601(now)
      def r(%Config{} = options), do: {options.root, options.env, options.clock}
      def s(%Config{} = options), do: {options.runner, options.repo, options.tmp}
      def t(%Config{} = options), do: {options.io, options.git, options.state}
      def u(%Config{} = options), do: {options.log, options.timeout, options.control}
    end
    """
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(CtxBag)
    |> refute_issues()
  end

  test "only scans configured lib paths" do
    "defmodule X do\n  def run(ctx), do: ctx\nend\n"
    |> to_source_file("test/build/x_test.exs")
    |> run_check(CtxBag)
    |> refute_issues()
  end
end
