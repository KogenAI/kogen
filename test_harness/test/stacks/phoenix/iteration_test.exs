defmodule CodegenTestHarness.Stacks.Phoenix.IterationTest do
  @moduledoc """
  Change-request scenario for the phoenix stack.

  Builds a todo app, then issues a second `codegen-build` in the same
  tmp_dir requesting a search input. Asserts:
  - a new git commit lands
  - contracted markers are present: data-testid="search", phx-change="search",
    handle_event("search"
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

  @change_prompt "Add a search input above the todo list. The HEEx MUST contain " <>
                   "<input data-testid=\"search\" phx-change=\"search\">. " <>
                   "The LiveView MUST handle_event(\"search\", %{\"value\" => q}, socket) " <>
                   "and filter the assigned todos by String.contains?/2 of q."

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir(stack: :phoenix)}
  end

  test "change request produces new commit and search markers", %{cwd: cwd} do
    {commits_before, commits_after} =
      Fixtures.change_request(cwd, @first_prompt, @change_prompt,
        stack: "phoenix",
        test_name: "iteration_phoenix_search"
      )

    assert commits_after > commits_before,
           "change request must produce at least one new commit. " <>
             "Before: #{commits_before}, after: #{commits_after}"

    # Find the todo LiveView file containing the search markers
    live_files =
      cwd
      |> Path.join("lib/*_web/live/**/*.ex")
      |> Path.wildcard()

    todo_files =
      Enum.filter(live_files, fn f ->
        f |> Path.basename() |> String.downcase() |> String.contains?("todo")
      end)

    fallback = Path.wildcard(Path.join(cwd, "lib/**/todo*.ex"))
    target_files = if todo_files == [], do: fallback, else: todo_files

    assert target_files != [],
           "No todo LiveView file found under lib/*_web/live/ or lib/**/todo*.ex in #{cwd}"

    [todo_live_path | _] = target_files

    Assertions.assert_file_matches!(todo_live_path, ~r/data-testid="search"/)
    Assertions.assert_file_matches!(todo_live_path, ~r/phx-change="search"/)
    Assertions.assert_file_matches!(todo_live_path, ~r/handle_event\("search"/)

    Assertions.assert_mix_compiles!(cwd)
    Assertions.assert_generated_tests_pass!(cwd)
    Assertions.assert_git_committed!(cwd)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_commit_subject_length!(cwd)
    Assertions.assert_not_revert_head!(cwd)
    Assertions.assert_renders!(cwd, :phoenix)
    Fixtures.bench_assertions_passed!("phoenix", "iteration_phoenix_search_scaffold")
    Fixtures.bench_assertions_passed!("phoenix", "iteration_phoenix_search_change")
  end
end
