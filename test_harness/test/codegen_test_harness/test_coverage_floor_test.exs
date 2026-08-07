defmodule CodegenTestHarness.TestCoverageFloorTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.TestCoverageFloor

  setup do
    dir =
      Path.join(System.tmp_dir!(), "test_coverage_floor_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    init_repo!(dir)
    {:ok, dir: dir}
  end

  defp git!(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  defp init_repo!(dir) do
    {_out, 0} = git!(dir, ["init", "-q"])
    {_out, 0} = git!(dir, ["config", "user.email", "t@example.com"])
    {_out, 0} = git!(dir, ["config", "user.name", "T"])
  end

  defp commit_all!(dir, message) do
    {_out, 0} = git!(dir, ["add", "-A"])
    {_out, 0} = git!(dir, ["commit", "-q", "-m", message])
  end

  defp head!(dir) do
    {out, 0} = git!(dir, ["rev-parse", "HEAD"])
    String.trim(out)
  end

  defp write!(dir, path, content) do
    absolute_path = Path.join(dir, path)
    absolute_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(absolute_path, content)
  end

  defp seed_elixir_pair!(dir) do
    write!(dir, "foo.ex", "defmodule Foo do\n  def go, do: :ok\nend\n")

    write!(
      dir,
      "foo_test.exs",
      "defmodule FooTest do\n  use ExUnit.Case\n  test \"one\", do: :ok\n  test \"two\", do: :ok\nend\n"
    )

    commit_all!(dir, "seed")
    head!(dir)
  end

  test "a surviving subject with fewer assertion blocks is refused", %{dir: dir} do
    base = seed_elixir_pair!(dir)

    write!(
      dir,
      "foo_test.exs",
      "defmodule FooTest do\n  use ExUnit.Case\n  test \"one\", do: :ok\nend\n"
    )

    commit_all!(dir, "remove coverage")

    assert {:error, reason} = TestCoverageFloor.check(dir, base)
    assert reason =~ "foo_test.exs lost test coverage"
    assert reason =~ "2 -> 1"
  end

  test "deleting the test together with its subject is allowed", %{dir: dir} do
    base = seed_elixir_pair!(dir)
    File.rm!(Path.join(dir, "foo.ex"))
    File.rm!(Path.join(dir, "foo_test.exs"))
    commit_all!(dir, "remove feature")

    assert TestCoverageFloor.check(dir, base) == :ok
  end

  test "deleting a test while its subject survives is refused", %{dir: dir} do
    base = seed_elixir_pair!(dir)
    File.rm!(Path.join(dir, "foo_test.exs"))
    commit_all!(dir, "remove test only")

    assert {:error, reason} = TestCoverageFloor.check(dir, base)
    assert reason =~ "foo_test.exs lost test coverage"
    assert reason =~ "2 -> 0"
  end

  test "deleting a test_harness test with its lib subject is allowed", %{dir: dir} do
    write!(dir, "test_harness/lib/codegen_test_harness/widget.ex", "defmodule Widget do\nend\n")

    write!(
      dir,
      "test_harness/test/codegen_test_harness/widget_test.exs",
      "test \"one\", do: :ok\ntest \"two\", do: :ok\n"
    )

    commit_all!(dir, "seed harness feature")
    base = head!(dir)
    File.rm!(Path.join(dir, "test_harness/lib/codegen_test_harness/widget.ex"))
    File.rm!(Path.join(dir, "test_harness/test/codegen_test_harness/widget_test.exs"))
    commit_all!(dir, "remove harness feature")

    assert TestCoverageFloor.check(dir, base) == :ok
  end

  test "a reasoned added exemption is allowed but an empty one is not", %{dir: dir} do
    base = seed_elixir_pair!(dir)

    write!(
      dir,
      "foo_test.exs",
      "# test-deletion-exempt: foo_test.exs — cases moved to integration\ntest \"one\", do: :ok\n"
    )

    commit_all!(dir, "move tests")
    assert TestCoverageFloor.check(dir, base) == :ok

    dir2 =
      Path.join(
        System.tmp_dir!(),
        "test_coverage_floor_empty_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir2)
    on_exit(fn -> File.rm_rf!(dir2) end)
    init_repo!(dir2)
    base2 = seed_elixir_pair!(dir2)

    write!(
      dir2,
      "foo_test.exs",
      "# test-deletion-exempt: foo_test.exs — \ntest \"one\", do: :ok\n"
    )

    commit_all!(dir2, "unreasoned move")

    assert {:error, _reason} = TestCoverageFloor.check(dir2, base2)
  end

  test "renames compare the old and new test blobs", %{dir: dir} do
    base = seed_elixir_pair!(dir)
    {_out, 0} = git!(dir, ["mv", "foo_test.exs", "renamed_test.exs"])
    commit_all!(dir, "rename")
    assert TestCoverageFloor.check(dir, base) == :ok

    base = head!(dir)
    write!(dir, "renamed_test.exs", "test \"one\", do: :ok\n")
    commit_all!(dir, "shrink renamed test")

    assert {:error, reason} = TestCoverageFloor.check(dir, base)
    assert reason =~ "renamed_test.exs"
  end

  test "each supported dialect detects a decrease", %{dir: dir} do
    cases = [
      {"script.sh", "script_test.sh", "run_test alpha\nrun_test beta\n", "run_test alpha\n"},
      {"tests/widget.py", "tests/test_widget.py", "def test_one(): pass\ndef test_two(): pass\n",
       "def test_one(): pass\n"},
      {"thing.ts", "thing.test.ts", "test('one', () => {})\nit('two', () => {})\n",
       "test('one', () => {})\n"}
    ]

    Enum.each(cases, fn {subject, test_path, before_content, after_content} ->
      write!(dir, subject, "subject\n")
      write!(dir, test_path, before_content)
      commit_all!(dir, "seed #{test_path}")
      base = head!(dir)
      write!(dir, test_path, after_content)
      commit_all!(dir, "shrink #{test_path}")
      assert {:error, reason} = TestCoverageFloor.check(dir, base)
      assert reason =~ test_path
    end)
  end

  test "an invalid base and a non-git directory fail closed, while nil skips the comparison", %{
    dir: dir
  } do
    assert {:error, reason} = TestCoverageFloor.check(dir, "does-not-exist")
    assert reason =~ "git diff"
    assert {:error, _reason} = TestCoverageFloor.check(Path.join(dir, "not-a-tree"), "abc")
    assert TestCoverageFloor.check(dir, nil) == :ok
  end

  test "every tracked supported test file has at least one assertion-bearing block" do
    repo_root = Path.expand("..", File.cwd!())
    {files, 0} = git!(repo_root, ["ls-files", "-z"])

    blind_spots =
      files
      |> String.split("\0", trim: true)
      |> Enum.flat_map(fn path ->
        absolute_path = Path.join(repo_root, path)

        if File.regular?(absolute_path) do
          case TestCoverageFloor.assertion_block_count(path, File.read!(absolute_path)) do
            nil -> []
            0 -> [path]
            _count -> []
          end
        else
          []
        end
      end)

    assert blind_spots == []
  end
end
