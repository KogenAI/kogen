defmodule CodegenTestHarness.Stacks.Static.CommitterTest do
  @moduledoc """
  Commit-quality assertions for the static stack.

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

  @prompt ~s(Build a single-page landing site for a coffee shop called Brew & Co. ) <>
            ~s(Include a <section id="hours"> with opening hours.)

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  test "commit is well-formed after static build", %{cwd: cwd} do
    Fixtures.run_codegen_build(cwd, @prompt,
      stack: "static",
      test_name: "committer_static_well_formed"
    )

    Assertions.assert_git_committed!(cwd)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_commit_subject_length!(cwd)
    Assertions.assert_not_revert_head!(cwd)
    Fixtures.bench_assertions_passed!("static", "committer_static_well_formed")
  end
end
