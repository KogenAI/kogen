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
  @moduletag timeout: 1_800_000

  @first_prompt ~s(Build a Phoenix LiveView todo app. The router MUST have ) <>
                  ~s(live "/", TodoLive, :index. TodoLive MUST render a ) <>
                  ~s(<form id="new-todo-form"> with an <input name="todo[title]"> ) <>
                  ~s(and a <button data-testid="add-todo">.)

  @second_prompt ~s(Add a footer to the TodoLive page with the text "Powered by Phoenix". ) <>
                   ~s(The footer MUST be wrapped in a <footer data-testid="app-footer"> element.)

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  test "second build from committed state produces fresh commit and still compiles", %{cwd: cwd} do
    # First build
    Fixtures.run_codegen_build(cwd, @first_prompt)

    Assertions.assert_mix_compiles!(cwd)
    commits_after_first = count_commits!(cwd)
    assert commits_after_first >= 1, "First build must produce at least one commit"

    # Second build from committed state
    Fixtures.run_codegen_build(cwd, @second_prompt)

    Assertions.assert_mix_compiles!(cwd)
    Assertions.assert_assets_deploy!(cwd)
    Assertions.assert_new_commit_since!(cwd, commits_after_first)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_not_revert_head!(cwd)
  end

  defp count_commits!(cwd) do
    {log, 0} =
      System.cmd("git", ["log", "--oneline"], cd: cwd, stderr_to_stdout: true, env: [])

    log |> String.split("\n", trim: true) |> length()
  end
end
