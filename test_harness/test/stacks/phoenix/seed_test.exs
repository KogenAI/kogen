defmodule CodegenTestHarness.Stacks.Phoenix.SeedTest do
  @moduledoc """
  Idempotent rebuild scenario for the phoenix stack.

  Builds an app from scratch, commits it, then runs a second `codegen-build`
  in the same directory (simulating a seed-restore scenario). Asserts:
  - the tree still compiles after both builds
  - a fresh commit lands from the second build
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 12_000_000

  @first_prompt ~s(Build a Phoenix LiveView todo app. The router MUST have ) <>
                  ~s(live "/", TodoLive, :index. TodoLive MUST render a ) <>
                  ~s(<form id="new-todo-form"> with an <input name="todo[title]"> ) <>
                  ~s(and a <button data-testid="add-todo">.)

  @second_prompt ~s(Add a footer to the TodoLive page with the text "Powered by Phoenix". ) <>
                   ~s(The footer MUST be wrapped in a <footer data-testid="app-footer"> element.)

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir(stack: :phoenix)}
  end

  test "second build from committed state produces fresh commit and still compiles", %{cwd: cwd} do
    # First build
    Fixtures.run_codegen_build(cwd, @first_prompt, test_name: "seed_phoenix_first_build")

    Assertions.assert_mix_compiles!(cwd)
    Assertions.assert_generated_tests_pass!(cwd)
    commits_after_first = Fixtures.count_commits!(cwd)
    assert commits_after_first >= 1, "First build must produce at least one commit"

    # Second build from committed state
    Fixtures.run_codegen_build(cwd, @second_prompt, test_name: "seed_phoenix_second_build")

    Assertions.assert_mix_compiles!(cwd)
    Assertions.assert_generated_tests_pass!(cwd)
    Assertions.assert_new_commit_since!(cwd, commits_after_first)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_not_revert_head!(cwd)

    # Verify 2nd-prompt marker landed in the TodoLive file
    live_files = Path.wildcard(Path.join(cwd, "lib/*_web/live/**/*.ex"))
    todo_files = Enum.filter(live_files, fn f -> f |> Path.basename() |> String.downcase() |> String.contains?("todo") end)
    fallback = Path.wildcard(Path.join(cwd, "lib/**/todo*.ex"))
    target_files = if todo_files == [], do: fallback, else: todo_files

    assert target_files != [],
           "no todo LiveView file found after second build — AI must create a TodoLive module"

    [todo_live_path | _] = target_files
    Assertions.assert_file_matches!(todo_live_path, ~r/data-testid="app-footer"/)

    Fixtures.bench_assertions_passed!("phoenix", "seed_phoenix_first_build")
    Fixtures.bench_assertions_passed!("phoenix", "seed_phoenix_second_build")
  end

end
