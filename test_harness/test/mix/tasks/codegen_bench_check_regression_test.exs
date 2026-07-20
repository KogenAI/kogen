defmodule Mix.Tasks.Codegen.Bench.CheckRegressionTest do
  @moduledoc """
  Hermetic tests for `mix codegen.bench.check-regression`. No LLM calls —
  fixture JSONL `harness_summary` records against the real, committed
  `perf_baseline.json`.

  `perf_baseline.json` only carries a non-zero baseline for `pass_rate`
  (`min_abs: 0.9`) — every `max_regression_pct` metric is still `baseline: 0`
  and therefore skipped by design (see repo `_note`). These tests exercise:

  1. no regression → exits :ok, no failure output
  2. pass_rate below min_abs → HARD failure regardless of --strict (exit
     {:shutdown, 1})
  3. `--strict` flag is accepted and parsed without raising
  4. missing --run directory raises
  5. missing baseline file (simulated via a run dir far from the fixed
     @baseline_path is not directly injectable — the task hardcodes the
     real repo path) is NOT tested here; @baseline_path is compile-time
     fixed to the real perf_baseline.json, which always exists in this repo.
  """

  # async: false — this module mutates process-global Mix.shell/1, which
  # races against any other concurrently-running module doing the same.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Codegen.Bench.CheckRegression

  setup do
    run_dir =
      Path.join(
        System.tmp_dir!(),
        "bench_check_regression_test_#{:erlang.unique_integer([:positive])}"
      )

    claude_dir = Path.join([run_dir, "runs", "claude", "phoenix"])
    File.mkdir_p!(claude_dir)
    on_exit(fn -> File.rm_rf!(run_dir) end)

    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    {:ok, run_dir: run_dir, claude_dir: claude_dir}
  end

  defp collect_shell_output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, :info, [msg]} -> msg
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.join("\n")
  end

  defp write_summary(claude_dir, test_name, assertion_passed) do
    summary = %{
      "type" => "harness_summary",
      "test_name" => test_name,
      "exit_code" => 0,
      "assertion_passed" => assertion_passed,
      "parsed" => %{
        "model" => "claude-haiku",
        "input_tokens" => 100,
        "output_tokens" => 50,
        "cost_usd" => 0.01,
        "build_duration_ms" => 120_000,
        "num_turns" => 3
      }
    }

    File.write!(Path.join(claude_dir, "#{test_name}.jsonl"), Jason.encode!(summary))
  end

  # ── 1: RED-then-GREEN — the core disarm this pitch fixes ────────────────────
  #
  # RED (pre-fix behaviour, still reachable via this same task pre-patch):
  # a pass_rate collapse to 0.0 (all assertions failing) produced only a
  # printed warning table and `:ok` — the task ALWAYS exited 0. That is the
  # exact bug: a real regression, silently non-fatal.
  #
  # GREEN (this test, against the patched task): the same fixture now raises
  # via exit({:shutdown, 1}) — pass_rate is a hard regression unconditionally.

  test "1: pass_rate below min_abs is a HARD failure even without --strict", ctx do
    # All assertions failing -> pass_rate 0.0, baseline min_abs is 0.9.
    write_summary(ctx.claude_dir, "test_a", false)

    assert catch_exit(CheckRegression.run(["--run", ctx.run_dir])) == {:shutdown, 1}

    assert collect_shell_output() =~ "FAILURES"
  end

  test "2: no regression -> exits :ok, reports no regressions", ctx do
    # All assertions passing -> pass_rate 1.0, matches baseline exactly.
    write_summary(ctx.claude_dir, "test_a", true)
    write_summary(ctx.claude_dir, "test_b", true)

    assert CheckRegression.run(["--run", ctx.run_dir]) == :ok

    assert_receive {:mix_shell, :info, ["perf-regression: no regressions detected"]}
  end

  test "3: --strict flag is parsed without raising", ctx do
    write_summary(ctx.claude_dir, "test_a", true)

    assert CheckRegression.run(["--run", ctx.run_dir, "--strict"]) == :ok
  end

  test "4: max_regression_pct metrics stay informational (exit :ok) without --strict",
       ctx do
    # pass_rate stays at 1.0 (no hard failure); zero-baseline metrics
    # (avg_cost_usd etc.) are skipped entirely regardless of their actual
    # values, per the documented zero-baseline-skip contract.
    write_summary(ctx.claude_dir, "test_a", true)

    assert CheckRegression.run(["--run", ctx.run_dir]) == :ok
  end

  test "5: missing --run directory raises", ctx do
    missing_dir = Path.join(ctx.run_dir, "does_not_exist")

    assert_raise Mix.Error, ~r/Run directory does not exist/, fn ->
      CheckRegression.run(["--run", missing_dir])
    end
  end

  # ── CLI-name wiring ─────────────────────────────────────────────────────────
  # Every test above calls CheckRegression.run/1 DIRECTLY, which bypasses Mix's
  # CLI task-name resolution. That blind spot let the Makefile invoke
  # `mix codegen.bench.check-regression` (dash) — a name Mix cannot resolve,
  # since it derives `codegen.bench.check_regression` (underscore) from the
  # module name and aliases no dashed spelling. Result: the final step of every
  # `make bench` run failed AFTER the token spend, and no test noticed.
  # These two tests pin the CLI name and the Makefile's use of it.

  test "6: task is resolvable under its underscore CLI name" do
    assert Mix.Task.get("codegen.bench.check_regression") == CheckRegression

    refute Mix.Task.get("codegen.bench.check-regression"),
           "dashed spelling must not be advertised — Mix cannot resolve it"
  end

  test "7: Makefile bench target invokes a task name Mix can actually resolve" do
    makefile = Path.expand("../../../../Makefile", __DIR__)

    invocations =
      makefile
      |> File.read!()
      |> then(&Regex.scan(~r/mix\s+(codegen\.bench\.[a-z_.-]+)/, &1))
      |> Enum.map(fn [_, task] -> task end)
      |> Enum.uniq()

    assert "codegen.bench.check_regression" in invocations,
           "Makefile no longer invokes the regression checker: #{inspect(invocations)}"

    for task <- invocations do
      assert Mix.Task.get(task),
             "Makefile invokes `mix #{task}`, which Mix cannot resolve to a task module"
    end
  end
end
