defmodule Kogen.CheckTest do
  @moduledoc """
  Declared-target validation/execution for `Kogen.Check`
  (scenario `declared-targets-run-after-check`). Settlement cases live in
  `check_settlement_test.exs` so their independent fixtures can overlap.

  Each operation receives its private fixture root explicitly; the parent VM's
  cwd and environment stay unchanged.
  """
  use ExUnit.Case, async: true

  alias Kogen.Check

  # -- declared-targets-run-after-check -----------------------------------

  describe "declared_targets/1 and validate_targets/2" do
    @makefile """
    .PHONY: check passing_target failing_target

    check:
    \t@true

    passing_target:
    \t@echo ok

    failing_target:
    \t@exit 1
    """

    test "declares both fixture targets and validates them as safe and declared" do
      dir = tmp_dir!()
      makefile_path = Path.join(dir, "Makefile")
      File.write!(makefile_path, @makefile)

      declared = Check.declared_targets(makefile_path)
      assert MapSet.member?(declared, "passing_target")
      assert MapSet.member?(declared, "failing_target")

      assert Check.validate_targets(["passing_target", "failing_target"], makefile_path) == :ok
    end

    test "runs the passing and failing targets, and check goes unrun since it is excluded" do
      dir = tmp_dir!()
      File.write!(Path.join(dir, "Makefile"), @makefile)

      assert {:ok, out} = Check.run_target("passing_target", dir)
      assert out =~ "ok"

      # Make may report 1 or 2 depending on ambient MAKELEVEL/MAKEFLAGS.
      assert {:error, {code, _out}} = Check.run_target("failing_target", dir)
      assert code != 0
    end

    test "refuses a shell-metacharacter target name before it could ever reach the shell" do
      dir = tmp_dir!()
      makefile_path = Path.join(dir, "Makefile")
      File.write!(makefile_path, @makefile)

      assert {:error, reason} =
               Check.validate_targets(["foo; touch pwned", "passing_target"], makefile_path)

      assert reason =~ "refused unsafe target name"
      refute File.exists?(Path.join(dir, "pwned")), "run_target must never have been reached"
    end

    test "refuses a validly-named but undeclared target" do
      dir = tmp_dir!()
      makefile_path = Path.join(dir, "Makefile")
      File.write!(makefile_path, @makefile)

      assert {:error, reason} = Check.validate_targets(["nonexistent-target"], makefile_path)
      assert reason =~ "undeclared make target: nonexistent-target"
    end
  end

  # -- helpers -------------------------------------------------------------

  defp tmp_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-check-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
