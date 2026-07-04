defmodule CodegenTestHarness.Stacks.Modes.DebugTest do
  @moduledoc """
  Asserts {harness}-debug.sh dispatches correctly and produces a diagnostic
  report (Root Cause + Evidence) WITHOUT writing any files.

  Covers the harness×mode cells: claude-debug, pi-debug.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 1_800_000

  @prompt "Investigate why CLAUDE.md mentions writing files with relative paths. " <>
            "Report root cause + evidence. Do not propose fixes."

  setup do
    cwd = Fixtures.isolated_tmp_dir()
    # Capture pre-run git state for "no files written" assertion
    {porcelain, 0} =
      System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true, env: [])

    {:ok, cwd: cwd, before_porcelain: porcelain}
  end

  test "debug mode emits diagnostic report and writes nothing",
       %{cwd: cwd, before_porcelain: before_porcelain} do
    {output, exit_code} =
      Fixtures.run_mode_launcher(cwd, :debug, @prompt, test_name: "debug_mode")

    assert exit_code == 0,
           "#{Fixtures.harness()}-debug exit #{exit_code}:\n#{output}"

    Assertions.assert_diagnostic_report_shape!(output)
    Assertions.assert_no_files_written!(cwd, before_porcelain)
    Fixtures.bench_assertions_passed!("modes", "debug_mode")
  end
end
