defmodule CodegenTestHarness.Stacks.Phoenix.CommitterTest do
  @moduledoc """
  Commit-quality assertions for the phoenix stack.

  After a `codegen-build` completes, verifies:
  - commit is well-formed (non-empty subject, no Co-Authored-By)
  - commit subject fits within the 72-character limit
  - HEAD is not a revert commit
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 6_600_000

  @prompt ~s(Build a Phoenix LiveView todo app. The router MUST have ) <>
            ~s(live "/", TodoLive, :index. TodoLive MUST render a ) <>
            ~s(<form id="new-todo-form"> with an <input name="todo[title]"> ) <>
            ~s(and a <button data-testid="add-todo">.)

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir(stack: :phoenix)}
  end

  test "commit is well-formed after phoenix build", %{cwd: cwd} do
    Fixtures.run_codegen_build(cwd, @prompt, stack: "phoenix")

    Assertions.assert_git_committed!(cwd)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_commit_subject_length!(cwd)
    Assertions.assert_not_revert_head!(cwd)
  end
end
