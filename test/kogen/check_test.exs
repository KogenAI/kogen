defmodule Kogen.CheckTest do
  @moduledoc """
  Table-driven tests for `Kogen.Check`: the Verification Record settlement
  rule (scenario `verification-record-must-match-candidate`) and declared
  target validation/execution (scenario `declared-targets-run-after-check`).

  `record_path/0` and `run_target/1` resolve relative paths against the
  process's current working directory, so tests that exercise them use
  `File.cd!/2` and are marked `async: false`.
  """
  use ExUnit.Case, async: false

  alias Kogen.Check

  # -- verification-record-must-match-candidate --------------------------

  describe "settled_pass?/2" do
    @candidate_id "candidate-abc123"
    @session_id "session-xyz789"

    @mismatch_cases [
      {"different candidate id",
       %{
         "candidate" => "some-other-candidate",
         "status" => "passed",
         "target" => "check",
         "session_id" => @session_id,
         "exit_code" => 0
       }},
      {"different session id",
       %{
         "candidate" => @candidate_id,
         "status" => "passed",
         "target" => "check",
         "session_id" => "some-other-session",
         "exit_code" => 0
       }},
      {"failed status",
       %{
         "candidate" => @candidate_id,
         "status" => "failed",
         "target" => "check",
         "session_id" => @session_id,
         "exit_code" => 1
       }},
      {"wrong target",
       %{
         "candidate" => @candidate_id,
         "status" => "passed",
         "target" => "test",
         "session_id" => @session_id,
         "exit_code" => 0
       }},
      {"nonzero check exit",
       %{
         "candidate" => @candidate_id,
         "status" => "passed",
         "target" => "check",
         "session_id" => @session_id,
         "exit_code" => 1
       }}
    ]

    for {{name, record}, index} <- Enum.with_index(@mismatch_cases) do
      test "case #{index}: #{name} does not settle a pass" do
        in_tmp_cwd(fn ->
          write_record(unquote(Macro.escape(record)))
          refute Check.settled_pass?(@candidate_id, @session_id)
        end)
      end
    end

    test "a missing Verification Record cannot settle a pass" do
      in_tmp_cwd(fn ->
        refute File.exists?(Check.record_path())
        refute Check.settled_pass?(@candidate_id, @session_id)

        assert Check.settlement_failure_reason(@candidate_id, @session_id) ==
                 "no Verification Record was written"
      end)
    end

    test "a record matching candidate, session, check target, status=passed, and exit_code=0 settles a pass" do
      in_tmp_cwd(fn ->
        write_record(%{
          "candidate" => @candidate_id,
          "status" => "passed",
          "target" => "check",
          "session_id" => @session_id,
          "exit_code" => 0
        })

        assert Check.settled_pass?(@candidate_id, @session_id)
      end)
    end

    defp write_record(record) do
      Check.invalidate!()
      path = Check.record_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(record))
    end
  end

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

      in_dir(dir, fn ->
        assert {:ok, out} = Check.run_target("passing_target")
        assert out =~ "ok"

        # The exact non-zero code make reports depends on ambient MAKELEVEL/
        # MAKEFLAGS (e.g. running nested inside `make check` itself makes
        # this a sub-make, which can report 2 instead of 1); only the
        # settled-failure fact matters, not the specific code.
        assert {:error, {code, _out}} = Check.run_target("failing_target")
        assert code != 0
      end)
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
    dir = Path.join(System.tmp_dir!(), "kogen-check-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp in_tmp_cwd(fun) do
    dir = tmp_dir!()
    in_dir(dir, fun)
  end

  defp in_dir(dir, fun) do
    File.cd!(dir, fun)
  end
end
