defmodule KogenChecks.Check.TestModuleShapeTest do
  use Credo.Test.Case

  alias KogenChecks.Check.TestModuleShape

  test "requires async: true" do
    "defmodule ATest do\n  use ExUnit.Case\n  test \"a\", do: :ok\nend\n"
    |> to_source_file("test/build/a_test.exs")
    |> run_check(TestModuleShape)
    |> assert_issue(fn i -> assert i.message =~ "async: true" end)
  end

  test "accepts the async testkit case template" do
    "defmodule ATest do\n  use Kogen.Testkit.Case\n  test \"a\", do: :ok\nend\n"
    |> to_source_file("test/build/a_test.exs")
    |> run_check(TestModuleShape)
    |> refute_issues()
  end

  test "serial allowed only via the protected allowlist" do
    "defmodule ATest do\n  use Kogen.ProcCase, async: false\n  test \"a\", do: :ok\nend\n"
    |> to_source_file("test/proc/a_test.exs")
    |> run_check(TestModuleShape, serial_allowed: ["test/proc/a_test.exs"])
    |> refute_issues()
  end

  test "parameterize multiplies the test count" do
    tests = Enum.map_join(1..8, "\n", &"  test \"t#{&1}\", %{p: p}, do: assert(p)")

    "defmodule PTest do\n  use ExUnit.Case, async: true, parameterize: [%{p: 1}, %{p: 2}, %{p: 3}, %{p: 4}]\n#{tests}\nend\n"
    |> to_source_file("test/build/p_test.exs")
    |> run_check(TestModuleShape, max_tests: 30)
    |> assert_issue(fn i -> assert i.message =~ "32 test runs (8 tests x 4 params" end)
  end

  test "caps each module independently" do
    tests = Enum.map_join(1..16, "\n", &"  test \"t#{&1}\", do: assert(true)")

    ("defmodule ATest do\n  use ExUnit.Case, async: true\n#{tests}\nend\n" <>
       "defmodule BTest do\n  use ExUnit.Case, async: true\n#{tests}\nend\n")
    |> to_source_file("test/build/multiple_test.exs")
    |> run_check(TestModuleShape, max_tests: 20)
    |> refute_issues()
  end

  test "ignores non-test files" do
    "defmodule S do\n  use ExUnit.Case\nend\n"
    |> to_source_file("test/support/s.ex")
    |> run_check(TestModuleShape)
    |> refute_issues()
  end
end
