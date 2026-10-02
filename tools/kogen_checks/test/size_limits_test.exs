defmodule KogenChecks.Check.SizeLimitsTest do
  use Credo.Test.Case

  alias KogenChecks.Check.SizeLimits

  defp body(n), do: Enum.map_join(1..n, "\n", fn i -> "    x#{i} = #{i}" end)

  test "flags a long function and a long module, not short ones" do
    """
    defmodule Big do
      def long do
    #{body(45)}
      end

      def short, do: :ok
    end
    """
    |> to_source_file("lib/kogen/build/big.ex")
    |> run_check(SizeLimits, max_function_lines: 40, max_module_lines: 40, max_file_lines: 400)
    |> assert_issues(fn issues ->
      triggers = issues |> Enum.map(& &1.trigger) |> Enum.sort()
      assert triggers == ["def long/0", "module Big"]
    end)
  end

  test "file ceiling" do
    ("defmodule F do\n" <> body(30) <> "\nend\n")
    |> to_source_file("lib/kogen/build/f.ex")
    |> run_check(SizeLimits, max_file_lines: 20, max_module_lines: 400, max_function_lines: 40)
    |> assert_issue(fn i -> assert i.message =~ "File has 33 lines" end)
  end
end
