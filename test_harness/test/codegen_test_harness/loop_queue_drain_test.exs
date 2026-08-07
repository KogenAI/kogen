defmodule CodegenTestHarness.LoopQueueDrainTest do
  use ExUnit.Case, async: true
  import CodegenTestHarness.AgentTeardown, only: [stop_agent: 1]
  import ExUnit.CaptureIO

  alias CodegenTestHarness.LoopQueueDrain

  setup do
    dir =
      Path.join(System.tmp_dir!(), "loop_queue_drain_test_#{:erlang.unique_integer([:positive])}")

    ready_dir = Path.join([dir, "codegen", "pitches", "ready"])
    shipped_dir = Path.join([dir, "codegen", "pitches", "shipped"])
    lock_path = Path.join([dir, "codegen", "pitches", "queue.lock"])
    File.mkdir_p!(ready_dir)
    File.mkdir_p!(shipped_dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, ready_dir: ready_dir, shipped_dir: shipped_dir, lock_path: lock_path}
  end

  # Production progress logging — the `[i/n] <slug> ... building` banner and
  # the `queue: GC codegen/logging — reclaimed ...` line — is written straight
  # to :stderr by design; operators watching a live drain need it. In the test
  # suite it is pure noise: it interleaves with ExUnit's own output and makes a
  # `make ci` failure dump unreadable. Routing every drain/1 call through
  # with_io(:stderr, ...) parks that output in the capture buffer instead of the
  # terminal WITHOUT suppressing it — an enclosing capture_io(:stderr, ...) still
  # sees every line (ExUnit's capture server shares one buffer per device), so
  # the tests that assert on the banner and the GC line keep working unchanged.
  defp quiet_drain(opts) do
    {result, _stderr} = ExUnit.CaptureIO.with_io(:stderr, fn -> LoopQueueDrain.drain(opts) end)
    result
  end

  defp write_pitch(ready_dir, slug, body \\ nil) do
    File.write!(Path.join(ready_dir, "#{slug}.md"), body || "# Pitch: #{slug}\n")
  end

  defp base_opts(ctx, extra) do
    defaults = [
      harness: "claude",
      stack: "phoenix",
      cwd: ctx.dir,
      ready_dir: ctx.ready_dir,
      shipped_dir: ctx.shipped_dir,
      lock_path: ctx.lock_path,
      sleep_fn: fn _secs -> :ok end,
      git_stash_fn: fn _cwd, _slug, _reason -> :ok end,
      git_stash_restore_fn: fn _cwd, _slug -> :ok end,
      # Hermetic-test guard: never let a FAILED-arm test fire a real,
      # billed `codegen-call` — see loop_queue_drain_test.exs's own draft_fn
      # tests for the stubs that override this default.
      draft_fn: fn _cwd, _slug, _jsonl, _gate_verdict -> {:ok, "/dev/null"} end,
      now_fn: fn -> 1_700_000_000 end,
      pid_alive_fn: fn _pid -> false end,
      git_head_fn: fn _cwd -> nil end,
      # Hermetic default: every pre-existing test uses a synthetic non-git
      # cwd, where the REAL BornDeadDetector.check/2 would hit `git diff`
      # failing non-zero and fail-closed — never the intended behavior for
      # tests that don't exercise the born-dead completeness leg itself. See
      # this file's dedicated "N: whole-pitch completeness" tests below for
      # the cases that override this to `{:error, _}`.
      born_dead_fn: fn _cwd, _base_sha -> :ok end,
      coverage_floor_fn: fn _cwd, _base_sha -> :ok end,
      gate_verdict_fn: fn _cwd -> "" end,
      gate_base_sha_fn: fn _cwd -> "" end,
      # Stale by default (older than any real spawn `ts`) — never-fresh,
      # preserving the semantics of every failure-path test that doesn't
      # opt into a real gate record.
      gate_mtime_fn: fn _cwd -> 0 end,
      terminal_marker_fn: fn _cwd -> :absent end,
      discover_session_log_fn: fn _cwd, _slug, _spawn_stamp -> nil end,
      blocked_fn: fn -> %{} end,
      # Hermetic no-op defaults: every existing test that doesn't explicitly
      # exercise publish must never touch the network. A ship without an
      # override "publishes" trivially; preflight always passes.
      git_publish_fn: fn _cwd, _slug -> {:ok, :unchanged} end,
      publish_preflight_fn: fn _cwd -> :ok end,
      # Hermetic-test guard: never let a transient-failure test shell a real
      # `claude --print` liveness probe. Default :up — every pre-existing
      # transient test expects the outage pause to resolve on its first
      # probe (mirrors immediate-retry semantics); tests exercising a
      # sustained outage override this explicitly.
      probe_fn: fn _state -> :up end,
      outage_pause_secs: 900
    ]

    Keyword.merge(defaults, extra)
  end

  # Fixture opts simulating a LEGITIMATE ship on the exit-0 path (see
  # LoopQueueDrain.handle_exit_zero/7): git_head_fn is called once per
  # do_run_slug invocation REGARDLESS of outcome (once for the pre-spawn
  # head_before read on EVERY attempt, including timeout/retry attempts that
  # never reach handle_exit_zero/handle_nonzero_exit — see do_run_slug's
  # `head_before = state.git_head_fn.(state.cwd)` above the result match).
  # git_head_fn returns a MONOTONICALLY INCREASING value on every call
  # ("head-0", "head-1", ...) — so any (head_before, head_after) pair for a
  # given attempt is guaranteed head_after != head_before (forward move),
  # independent of how many extra calls earlier timeout attempts consumed.
  #
  # The gate runs BEFORE the deterministic commit step (loop step order), so a real gate
  # record's base_sha can only ever equal the head AT GATE TIME — i.e. this
  # attempt's head_before, the value git_head_fn returned on the call
  # immediately BEFORE the current (most recent) one. gate_verdict_fn/
  # gate_base_sha_fn track that PREVIOUS head value, not the latest.
  # gate_mtime_fn always reports "now" (>= the frozen now_fn), so the
  # freshness mtime leg is always satisfied here.
  #
  # SAFE for: exit-0-only sequences, and TIMEOUT-then-exit-0 sequences
  # (timeout attempts never reach handle_nonzero_exit, so its
  # post-commit-hiccup ship branches are never evaluated with this
  # fixture's "clear" verdict).
  #
  # UNSAFE for: sequences with a NONZERO-exit attempt before the real
  # exit-0 ship (e.g. transient-retry-then-ship) — a nonzero attempt DOES
  # reach handle_nonzero_exit/7, which shares this same "always clear"
  # verdict and would spuriously trip its post-commit-hiccup
  # branches (shipping early, on the wrong attempt, before the intended
  # retry). Tests with that shape need a bespoke fixture (see test 4,
  # 6r3, 6f above) that keeps the gate non-clear until the exit-0 attempt.
  defp shipped_opts(ctx, extra) do
    head_calls = start_agent(0)
    prev_head = start_agent("")
    cur_head = start_agent("")

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      head = "head-#{n}"
      Agent.update(prev_head, fn _ -> Agent.get(cur_head, & &1) end)
      Agent.update(cur_head, fn _ -> head end)
      head
    end

    gate_verdict_fn = fn _cwd -> "clear" end
    gate_base_sha_fn = fn _cwd -> Agent.get(prev_head, & &1) end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end

    base_opts(
      ctx,
      Keyword.merge(
        [
          git_head_fn: git_head_fn,
          gate_verdict_fn: gate_verdict_fn,
          gate_base_sha_fn: gate_base_sha_fn,
          gate_mtime_fn: gate_mtime_fn
        ],
        extra
      )
    )
  end

  defp start_agent(initial) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  # ── 1. Ordering (deps-first) ────────────────────────────────────────────

  test "1: ordering — deps-first spawn order, both shipped", ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b", "# Pitch: b\n\nBlocks-on: a\n")

    calls = start_agent([])

    spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
      Agent.update(calls, &(&1 ++ [slug]))
      {:exit_code, 0}
    end

    assert {:ok, 2} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
    assert Agent.get(calls, & &1) == ["a", "b"]
    refute File.exists?(Path.join(ctx.ready_dir, "a.md"))
    refute File.exists?(Path.join(ctx.ready_dir, "b.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "a.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "b.md"))
  end

  # ── N. Whole-pitch completeness (born_dead_fn) ──────────────────────────
  # Same fail-closed check `OrchestrationLoop.assert_work_produced!/2` raises
  # on for a solo build — see BornDeadDetector moduledoc. Both floors (solo
  # raise, drain seam) must move together so a drained build can't bypass
  # the completeness check the solo build enforces. See also N3 below for
  # the default-seam (unmocked) fail-closed proof.

  test "N1: born_dead_fn returning {:error, _} on an otherwise-clear committed cycle refuses to ship",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    born_dead_fn = fn _cwd, _base_sha ->
      {:error, "born-dead detector: new entity \"orphan_module.ex\" has no live caller"}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, born_dead_fn: born_dead_fn))
      end)

    # Never shipped — the pitch stays in ready/ (draft_fn is stubbed as a
    # no-op in this fixture; the real drain would move it to draft/). A
    # single deterministic failure (below max_consecutive_fails) is drafted
    # and the drain exits cleanly with zero shipped rather than HALTing.
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    refute File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    assert output =~ "exit 0 but no verified commit under a fresh clear gate"
    assert output =~ "whole_pitch?=false"
  end

  test "N2: born_dead_fn returning :ok on a fully clear committed cycle ships normally", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    born_dead_fn = fn _cwd, _base_sha -> :ok end

    assert {:ok, 1} =
             quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, born_dead_fn: born_dead_fn))

    refute File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "N3: default born_dead_fn (unset opts) is the real BornDeadDetector — fails closed on an unparseable (non-git) tree rather than silently shipping",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    # Deliberately omit :born_dead_fn from shipped_opts's extras — proves the
    # DEFAULT wiring is the real detector, not a permissive no-op. ctx.dir is
    # not a real git repo, so `git diff` fails and the real detector reports
    # {:error, _} — the drain must treat this exactly like any other
    # unverified commit (refuse to ship), never silently pass through.
    opts = shipped_opts(ctx, spawn_fn: spawn_fn) |> Keyword.delete(:born_dead_fn)

    assert {:ok, 0} = quiet_drain(opts)
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    refute File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "N4: coverage_floor_fn returning an error on an otherwise-clear committed cycle refuses to ship",
       ctx do
    write_pitch(ctx.ready_dir, "solo")
    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    coverage_floor_fn = fn _cwd, _base_sha ->
      {:error, "test-coverage-floor: test/foo_test.exs lost test coverage — 22 -> 2"}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   shipped_opts(ctx, spawn_fn: spawn_fn, coverage_floor_fn: coverage_floor_fn)
                 )
      end)

    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    refute File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    assert output =~ "coverage_floor_ok?=false"
    assert output =~ "coverage_floor_reason="
    assert output =~ "test-coverage-floor"

    failure_history = File.read!(Path.join(ctx.ready_dir, "solo.md"))
    assert failure_history =~ "cause=test_coverage_floor; owner=drain/test-coverage-floor"
    assert failure_history =~ "detail=test-coverage-floor: test/foo_test.exs lost test coverage"
  end

  test "1b: jsonl filename uses UTC YYYYMMDD_HHMMSS stamp, not raw epoch", ctx do
    write_pitch(ctx.ready_dir, "solo")

    jsonl_path = start_agent(nil)

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      Agent.update(jsonl_path, fn _ -> jsonl end)
      {:exit_code, 0}
    end

    assert {:ok, 1} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))

    captured = Agent.get(jsonl_path, & &1)
    assert Path.basename(captured) == "20231114_221320_solo_build.log"
    assert Path.basename(captured) =~ ~r/^[0-9]{8}_[0-9]{6}_/
  end

  # ── 1c. Progress banner / two-path echo / terminal lines ────────────────

  test "1c: banner emits [1/1] slug ... building", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      end)

    assert output =~ ~r/\[1\/1\] solo \.\.\. building/
  end

  test "1d: idx/total computed once across 2 pitches (b Blocks-on a)", ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b", "# Pitch: b\n\nBlocks-on: a\n")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 2} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      end)

    assert output =~ "[1/2] a ... building"
    assert output =~ "[2/2] b ... building"
  end

  test "1e: two-path echo — session log primary, build log secondary", ctx do
    write_pitch(ctx.ready_dir, "solo")

    jsonl_path = start_agent(nil)

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      Agent.update(jsonl_path, fn _ -> jsonl end)
      {:exit_code, 0}
    end

    discover_session_log_fn = fn _cwd, slug, _stamp -> "/path/#{slug}_cycle.jsonl" end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} =
                 quiet_drain(
                   shipped_opts(ctx,
                     spawn_fn: spawn_fn,
                     discover_session_log_fn: discover_session_log_fn
                   )
                 )
      end)

    # session log (`_cycle.jsonl`, the real per-role record) and build log
    # (`_build.log`, the raw console capture) are DIFFERENT artifacts —
    # both are echoed.
    assert output =~ "/path/solo_cycle.jsonl"
    assert output =~ Path.basename(Agent.get(jsonl_path, & &1))
  end

  test "1f: build log echoed alone when discover_session_log_fn returns nil", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} =
                 quiet_drain(
                   shipped_opts(ctx,
                     spawn_fn: spawn_fn,
                     discover_session_log_fn: fn _, _, _ -> nil end
                   )
                 )
      end)

    refute output =~ "session log:"
    assert output =~ "_solo_build.log"
  end

  test "1g: default_discover_session_log/3 finds newest at/after spawn stamp, excludes stale",
       ctx do
    logging_dir = Path.join([ctx.dir, "codegen", "logging"])
    File.mkdir_p!(logging_dir)

    stale = Path.join(logging_dir, "20200101_000000_solo_cycle.jsonl")
    newest = Path.join(logging_dir, "20231114_221320_solo_cycle.jsonl")
    File.write!(stale, "# stale\n")
    File.write!(newest, "# newest\n")

    assert LoopQueueDrain.default_discover_session_log(ctx.dir, "solo", "20231114_221320") ==
             newest

    File.rm!(newest)

    # max_polls: 0 keeps this assertion instant (zero Process.sleep calls,
    # vs. the production default of 30 x 1s) while still exercising the real
    # bounded-retry-then-nil fail-open branch of poll_discover_session_log/4.
    assert LoopQueueDrain.default_discover_session_log(
             ctx.dir,
             "solo",
             "20231114_221320",
             0
           ) == nil
  end

  test "1g2: GC deletes build forensics past 30d, gzips 14-30d, keeps recent", ctx do
    logging_dir = Path.join([ctx.dir, "codegen", "logging"])
    File.mkdir_p!(logging_dir)

    ancient_build = Path.join(logging_dir, "20200101_000000_ancient_build.log")
    aging_build = Path.join(logging_dir, "20200601_000000_aging_build.jsonl")
    recent_build = Path.join(logging_dir, "20991231_000000_recent_build.log")

    File.write!(ancient_build, "ancient console capture\n")
    File.write!(aging_build, "aging jsonl capture\n")
    File.write!(recent_build, "recent console capture\n")

    thirty_one_days_ago = System.system_time(:second) - 31 * 24 * 3600
    twenty_days_ago = System.system_time(:second) - 20 * 24 * 3600
    :ok = File.touch(ancient_build, thirty_one_days_ago)
    :ok = File.touch(aging_build, twenty_days_ago)

    assert {:ok, 0} = quiet_drain(base_opts(ctx, []))

    refute File.exists?(ancient_build)
    refute File.exists?(aging_build)
    assert File.exists?(aging_build <> ".gz")
    assert File.exists?(recent_build)
  end

  test "1g3: GC never touches the active cycle log or gate-verdicts.jsonl", ctx do
    logging_dir = Path.join([ctx.dir, "codegen", "logging"])
    File.mkdir_p!(logging_dir)

    active_cycle = Path.join(logging_dir, "20200101_000000_solo_cycle.jsonl")
    gate_verdicts = Path.join(logging_dir, "gate-verdicts.jsonl")

    File.write!(active_cycle, ~s({"ev":"init"}\n))
    File.write!(gate_verdicts, ~s({"verdict":"clear"}\n))
    File.write!(Path.join(logging_dir, ".active"), active_cycle)

    ancient = System.system_time(:second) - 200 * 24 * 3600
    :ok = File.touch(active_cycle, ancient)
    :ok = File.touch(gate_verdicts, ancient)

    assert {:ok, 0} = quiet_drain(base_opts(ctx, []))

    assert File.exists?(active_cycle)
    refute File.exists?(active_cycle <> ".gz")
    assert File.exists?(gate_verdicts)
    assert File.read!(gate_verdicts) == ~s({"verdict":"clear"}\n)
  end

  test "1g4: GC gzips a non-active cycle log past 90d, deletes session-md and failures past 30d, gzips+deletes transcript dirs",
       ctx do
    logging_dir = Path.join([ctx.dir, "codegen", "logging"])
    failures_dir = Path.join(logging_dir, "failures")
    File.mkdir_p!(failures_dir)

    old_cycle = Path.join(logging_dir, "20200101_000000_old_cycle.jsonl")
    session_md = Path.join(logging_dir, "20200101_000000_old_session.md")
    failure_dump = Path.join(failures_dir, "abc-123.jsonl")

    aging_transcript_dir = Path.join(logging_dir, "20200601_000000_aging-slug")
    ancient_transcript_dir = Path.join(logging_dir, "20200101_000000_ancient-slug")
    File.mkdir_p!(aging_transcript_dir)
    File.mkdir_p!(ancient_transcript_dir)

    File.write!(
      Path.join(aging_transcript_dir, "01-developer-phoenix-backend.jsonl"),
      "developer turn\n"
    )

    File.write!(Path.join(ancient_transcript_dir, "01-developer.jsonl"), "developer turn\n")

    File.write!(old_cycle, ~s({"ev":"init"}\n))
    File.write!(session_md, "# old session\n")
    File.write!(failure_dump, ~s({"result":"boom"}\n))

    ninety_one_days_ago = System.system_time(:second) - 91 * 24 * 3600
    thirty_one_days_ago = System.system_time(:second) - 31 * 24 * 3600
    forty_six_days_ago = System.system_time(:second) - 46 * 24 * 3600
    twenty_days_ago = System.system_time(:second) - 20 * 24 * 3600

    :ok = File.touch(old_cycle, ninety_one_days_ago)
    :ok = File.touch(session_md, thirty_one_days_ago)
    :ok = File.touch(failure_dump, thirty_one_days_ago)
    :ok = File.touch(ancient_transcript_dir, forty_six_days_ago)
    :ok = File.touch(aging_transcript_dir, twenty_days_ago)

    assert {:ok, 0} = quiet_drain(base_opts(ctx, []))

    refute File.exists?(old_cycle)
    assert File.exists?(old_cycle <> ".gz")
    refute File.exists?(session_md)
    refute File.exists?(failure_dump)
    refute File.exists?(ancient_transcript_dir)
    assert File.dir?(aging_transcript_dir)

    assert File.exists?(Path.join(aging_transcript_dir, "01-developer-phoenix-backend.jsonl.gz"))
    refute File.exists?(Path.join(aging_transcript_dir, "01-developer-phoenix-backend.jsonl"))
  end

  test "1g5: GC prints a per-class reclaimed-bytes summary line to stderr", ctx do
    logging_dir = Path.join([ctx.dir, "codegen", "logging"])
    File.mkdir_p!(logging_dir)

    ancient_build = Path.join(logging_dir, "20200101_000000_ancient_build.log")
    File.write!(ancient_build, "ancient console capture\n")
    thirty_one_days_ago = System.system_time(:second) - 31 * 24 * 3600
    :ok = File.touch(ancient_build, thirty_one_days_ago)

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} = quiet_drain(base_opts(ctx, []))
      end)

    assert output =~ "queue: GC codegen/logging — reclaimed"
    assert output =~ "build-forensics"
    assert output =~ "transcripts"
    assert output =~ "session-md"
    assert output =~ "failures"
    assert output =~ "kept cycle-logs"
    assert output =~ "gate-verdicts"
  end

  test "1h: failure diagnostics on isolated skip — result/session_id surfaced, FAILED line emitted",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      File.write!(jsonl, ~s({"type":"result","result":"boom","session_id":"sess-123"}\n))
      {:exit_code, 1}
    end

    transient_fn = fn _jsonl -> false end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

    assert output =~ "boom"
    assert output =~ "session_id: sess-123"
    assert output =~ ~r/\[1\/1\] solo \.\.\. FAILED/
    assert output =~ "queue: FAILED bucket: solo"
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
  end

  test "1h3: failure diagnostics fall back to terminal_reason/subtype when result is absent",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      File.write!(
        jsonl,
        ~s({"type":"result","subtype":"error","terminal_reason":"loop_failed","session_id":"sess-x"}\n)
      )

      {:exit_code, 1}
    end

    transient_fn = fn _jsonl -> false end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

    assert output =~ "terminal: loop_failed (error)"
    assert output =~ "session_id: sess-x"
    assert output =~ ~r/\[1\/1\] solo \.\.\. FAILED/
  end

  test "1h2: a terminal-marked nonzero exit parks + skips — NEVER retried, even though transient_fn is true",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      File.write!(jsonl, ~s({"type":"result","result":"boom","session_id":"sess-123"}\n))
      {:exit_code, 1}
    end

    # transient_fn returns true — WITHOUT the terminal marker this would be
    # retry-eligible. The marker must be read and win BEFORE
    # retry_eligible?/5 is ever consulted (the ~$17 blind-retry this pitch
    # closes).
    transient_fn = fn _jsonl -> true end

    terminal_marker_fn = fn _cwd ->
      {:terminal, "gate verdict=failed", "developer-phoenix-backend"}
    end

    git_stash_fn = fn _cwd, _slug, _reason -> {:ok, "queue-fail/solo/20260101"} end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     terminal_marker_fn: terminal_marker_fn,
                     git_stash_fn: git_stash_fn
                   )
                 )
      end)

    assert output =~ "FAILED (deterministic: developer-phoenix-backend exhausted"
    assert output =~ "gate verdict=failed"
    assert output =~ "parked, not retried"
    refute output =~ "failed (retrying)"
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
  end

  test "1h3: an UNMARKED nonzero exit still resumes via the outage pause (regression guard — the diversion is narrow)",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    {:ok, attempts_agent} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> stop_agent(attempts_agent) end)

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      n = Agent.get_and_update(attempts_agent, fn n -> {n, n + 1} end)

      if n == 0 do
        File.write!(jsonl, ~s({"type":"result","result":"boom #{n}","session_id":"sess-#{n}"}\n))
        {:exit_code, 1}
      else
        {:exit_code, 0}
      end
    end

    # No terminal_marker_fn override — base_opts/2 defaults to :absent
    # (no on-disk marker). transient_fn true now routes through the outage
    # pause (before retry_eligible?/5 is ever consulted) — unchanged in that
    # it still is NOT the deterministic-failure park+skip+breaker path.
    transient_fn = fn _jsonl -> true end

    output =
      capture_io(:stderr, fn ->
        # git_head_fn defaults to nil (base_opts) -> exit-0 on attempt 2
        # cannot be verified as a real commit, so it lands in the
        # false-exit-0 FAILED arm rather than shipping — the point of this
        # regression guard is that the outage pause fires and resumes
        # exactly once (attempt count == 2), not the eventual outcome.
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     max_retries: 1
                   )
                 )
      end)

    assert Agent.get(attempts_agent, & &1) == 2
    assert output =~ "provider outage detected"
    assert output =~ "provider recovered — resuming solo"
  end

  test "1i: streaming tee — child stdout/stderr echoed to :stderr AND persisted to jsonl", ctx do
    jsonl = Path.join(ctx.dir, "out.jsonl")

    script =
      Path.join(ctx.dir, "echoer_tee.sh")

    File.write!(script, """
    #!/usr/bin/env bash
    printf 'OUT'
    printf 'ERR' >&2
    exit 0
    """)

    File.chmod!(script, 0o755)

    Process.put(:__queue_drain_build_bin__, script)
    on_exit(fn -> Process.delete(:__queue_drain_build_bin__) end)

    output =
      capture_io(:stderr, fn ->
        result = LoopQueueDrain.default_spawn_fn("slug", "claude", "phoenix", ctx.dir, jsonl)
        assert result == {:exit_code, 0}
      end)

    assert output =~ "OUT"
    assert output =~ "ERR"
    contents = File.read!(jsonl)
    assert contents =~ "OUT"
    assert contents =~ "ERR"
  end

  # ── 2. Cycle raises ─────────────────────────────────────────────────────

  test "2: Blocks-on: cycle raises", ctx do
    write_pitch(ctx.ready_dir, "a", "# Pitch: a\n\nBlocks-on: b\n")
    write_pitch(ctx.ready_dir, "b", "# Pitch: b\n\nBlocks-on: a\n")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    assert_raise RuntimeError, ~r/cyclic/, fn ->
      quiet_drain(base_opts(ctx, spawn_fn: spawn_fn))
    end
  end

  # ── 3. Ship-success ─────────────────────────────────────────────────────

  test "3: ship-success — child exit 0 moves ready -> shipped", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    assert {:ok, 1} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
    refute File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  # ── 3i. ship/3 idempotency (agent already shipped) ──────────────────────

  describe "ship/3 idempotency" do
    test "normal exit-0: agent already shipped -> ship/3 no-ops, no RenameError", ctx do
      write_pitch(ctx.ready_dir, "solo")

      # simulate the real build agent: it moves ready/<slug>.md -> shipped/
      # itself (per build system prompt) before returning exit 0.
      spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
        File.rename!(
          Path.join(ctx.ready_dir, "#{slug}.md"),
          Path.join(ctx.shipped_dir, "#{slug}.md")
        )

        {:exit_code, 0}
      end

      assert {:ok, 1} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      refute File.exists?(Path.join(ctx.ready_dir, "solo.md"))
      assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    end

    test "fallback: agent left pitch in ready/ -> drain moves it", ctx do
      write_pitch(ctx.ready_dir, "solo")

      # non-compliant agent: exits 0 but never ships (leaves ready/<slug>.md).
      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

      assert {:ok, 1} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      refute File.exists?(Path.join(ctx.ready_dir, "solo.md"))
      assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    end

    test "anomaly: pitch in neither ready/ nor shipped/ raises naming the slug", ctx do
      write_pitch(ctx.ready_dir, "solo")

      # pathological agent: removes the pitch from ready/ without shipping it.
      spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
        File.rm!(Path.join(ctx.ready_dir, "#{slug}.md"))
        {:exit_code, 0}
      end

      assert_raise RuntimeError, ~r/solo in neither ready.*nor shipped/, fn ->
        quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      end
    end
  end

  # ── publish: git_publish_fn / publish_preflight_fn seams ────────────────

  describe "drain/1 publish" do
    test "exit-0 ship: unchanged publish moves pitch, stderr names published sha", ctx do
      write_pitch(ctx.ready_dir, "solo")
      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

      git_publish_fn = fn _cwd, _slug -> {:ok, :unchanged} end

      output =
        capture_io(:stderr, fn ->
          assert {:ok, 1} =
                   quiet_drain(
                     shipped_opts(ctx, spawn_fn: spawn_fn, git_publish_fn: git_publish_fn)
                   )
        end)

      assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
      assert output =~ "shipped, published"
    end

    test "rewritten publish: ship record stamped with the post-rebase sha, not the original",
         ctx do
      System.cmd("git", ["init", "-q", ctx.dir])
      System.cmd("git", ["-C", ctx.dir, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", ctx.dir, "config", "user.name", "Test"])
      System.cmd("git", ["-C", ctx.dir, "config", "commit.gpgsign", "false"])

      write_pitch(ctx.ready_dir, "solo", "---\nstatus: ready\n---\n# Pitch: solo\n")
      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

      git_publish_fn = fn _cwd, _slug -> {:ok, {:rewritten, "newsha123"}} end

      assert {:ok, 1} =
               quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, git_publish_fn: git_publish_fn))

      content = File.read!(Path.join(ctx.shipped_dir, "solo.md"))
      assert content =~ "shipped_sha: newsha123"
    end

    test "conflict publish: halts, pitch stays in ready/, drain does not continue", ctx do
      write_pitch(ctx.ready_dir, "solo")
      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

      git_publish_fn = fn _cwd, _slug -> {:error, "rebase conflict: boom"} end

      assert {:error, reason} =
               quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, git_publish_fn: git_publish_fn))

      assert reason =~ "HALTED"
      assert reason =~ "solo"
      assert reason =~ "could not publish"
      assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
      refute File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    end

    test "preflight refusal: halts BEFORE any spawn — $0 spent", ctx do
      write_pitch(ctx.ready_dir, "solo")
      spawn_calls = start_agent(0)

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl ->
        Agent.update(spawn_calls, &(&1 + 1))
        {:exit_code, 0}
      end

      publish_preflight_fn = fn _cwd -> {:error, "no upstream"} end

      assert {:error, reason} =
               quiet_drain(
                 base_opts(ctx, spawn_fn: spawn_fn, publish_preflight_fn: publish_preflight_fn)
               )

      assert reason =~ "no upstream"
      assert Agent.get(spawn_calls, & &1) == 0
    end

    test "both handle_nonzero_exit ship arms publish: child-already-shipped", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
        File.rename!(
          Path.join(ctx.ready_dir, "#{slug}.md"),
          Path.join(ctx.shipped_dir, "#{slug}.md")
        )

        {:exit_code, 1}
      end

      publish_calls = start_agent(0)

      git_publish_fn = fn _cwd, _slug ->
        Agent.update(publish_calls, &(&1 + 1))
        {:ok, :unchanged}
      end

      assert {:ok, 1} =
               quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, git_publish_fn: git_publish_fn))

      assert Agent.get(publish_calls, & &1) == 1
    end

    test "both handle_nonzero_exit ship arms publish: drain-fallback (still in ready/)", ctx do
      write_pitch(ctx.ready_dir, "solo")
      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end

      publish_calls = start_agent(0)

      git_publish_fn = fn _cwd, _slug ->
        Agent.update(publish_calls, &(&1 + 1))
        {:ok, :unchanged}
      end

      assert {:ok, 1} =
               quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, git_publish_fn: git_publish_fn))

      assert Agent.get(publish_calls, & &1) == 1
      assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    end

    test "nonzero child-already-shipped arm refuses a failed coverage floor", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
        File.rename!(
          Path.join(ctx.ready_dir, "#{slug}.md"),
          Path.join(ctx.shipped_dir, "#{slug}.md")
        )

        {:exit_code, 1}
      end

      publish_calls = start_agent(0)

      git_publish_fn = fn _cwd, _slug ->
        Agent.update(publish_calls, &(&1 + 1))
        {:ok, :unchanged}
      end

      coverage_floor_fn = fn _cwd, _base_sha -> {:error, "test coverage shrank"} end

      assert {:ok, 0} =
               quiet_drain(
                 shipped_opts(ctx,
                   spawn_fn: spawn_fn,
                   git_publish_fn: git_publish_fn,
                   coverage_floor_fn: coverage_floor_fn
                 )
               )

      assert Agent.get(publish_calls, & &1) == 0
    end

    test "nonzero ready-dir fallback arm refuses a failed coverage floor", ctx do
      write_pitch(ctx.ready_dir, "solo")
      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      publish_calls = start_agent(0)
      failure_blocks = start_agent([])

      git_publish_fn = fn _cwd, _slug ->
        Agent.update(publish_calls, &(&1 + 1))
        {:ok, :unchanged}
      end

      coverage_floor_fn = fn _cwd, _base_sha -> {:error, "test coverage shrank"} end

      draft_fn = fn _cwd, _slug, _jsonl, failure_block ->
        Agent.update(failure_blocks, &[failure_block | &1])
        {:ok, "/dev/null"}
      end

      assert {:ok, 0} =
               quiet_drain(
                 shipped_opts(ctx,
                   spawn_fn: spawn_fn,
                   git_publish_fn: git_publish_fn,
                   coverage_floor_fn: coverage_floor_fn,
                   draft_fn: draft_fn
                 )
               )

      assert Agent.get(publish_calls, & &1) == 0
      assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
      assert [failure_block] = Agent.get(failure_blocks, & &1)
      assert failure_block =~ "Failure cause: test_coverage_floor — test coverage shrank"

      failure_history = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      assert failure_history =~ "cause=test_coverage_floor; owner=drain/test-coverage-floor"
      assert failure_history =~ "detail=test coverage shrank"
    end
  end

  # ── 4. Transient failure -> outage pause (probe :up) -> resume -> ship ──

  test "4: transient failure pauses, probes :up on first check, resumes and ships", ctx do
    write_pitch(ctx.ready_dir, "solo")

    attempts = start_agent(0)
    sleeps = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      n = Agent.get_and_update(attempts, fn n -> {n, n + 1} end)

      if n == 0 do
        File.write!(jsonl, "no result record here")
        {:exit_code, 1}
      else
        {:exit_code, 0}
      end
    end

    # Attempt 1 (nonzero) must NOT look committed/clear — else
    # handle_nonzero_exit/7's post-commit-hiccup branch would ship
    # on attempt 1, short-circuiting the intended retry. HEAD stays "aaa"
    # through attempt 1's head_before/head_after pair (gate "" too), then
    # moves to "bbb" for attempt 2's pair once the retry actually spawns
    # again — satisfying handle_exit_zero/7's committed + fresh-clear check.
    head_calls = start_agent(0)

    # calls: 0 = attempt1 head_before, 1 = attempt1 head_after (both "aaa",
    # not moved -> committed? false, safe from the hiccup branch regardless
    # of gate_clear?), 2 = attempt2 head_before ("aaa"), 3 = attempt2
    # head_after ("bbb", moved -> committed? true).
    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 3, do: "bbb", else: "aaa"
    end

    gate_calls = start_agent(0)

    # gate_verdict_fn is called once per handler: call 0 = attempt1
    # (nonzero, must NOT be clear — committed? is already false here so this
    # is belt-and-suspenders), call 1 = attempt2 (exit 0, must be clear).
    gate_verdict_fn = fn _cwd ->
      n = Agent.get_and_update(gate_calls, fn n -> {n, n + 1} end)
      if n == 1, do: "clear", else: "failed"
    end

    # Gate ran before the commit — base_sha matches head_before ("aaa" for
    # attempt 2), never head_after ("bbb").
    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end
    transient_fn = fn _jsonl -> true end
    sleep_fn = fn secs -> Agent.update(sleeps, &(&1 ++ [secs])) end

    assert {:ok, 1} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn,
                 gate_base_sha_fn: gate_base_sha_fn,
                 gate_mtime_fn: gate_mtime_fn,
                 transient_fn: transient_fn,
                 sleep_fn: sleep_fn
               )
             )

    assert Agent.get(attempts, & &1) == 2
    # probe_fn defaults to :up (base_opts) — the pause resolves on its FIRST
    # probe, before any sleep, unlike the old retry-ladder path.
    assert Agent.get(sleeps, & &1) == []
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  # ── 5. Sustained provider outage -> HALTs distinctly, never a skip ─────

  test "5: sustained transient outage HALTs with a distinct message, never 'consecutive deterministic failures', pitch stays in ready/",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    sleeps = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> true end
    # Provider never recovers within the pause ceiling.
    probe_fn = fn _state -> :down end
    sleep_fn = fn secs -> Agent.update(sleeps, &(&1 ++ [secs])) end

    output =
      capture_io(:stderr, fn ->
        assert {:error, reason} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     probe_fn: probe_fn,
                     sleep_fn: sleep_fn,
                     # Tiny ceiling relative to the (jittered ~24-96s) first
                     # probe delay so the pause exhausts on its very first
                     # sleep — deterministic, no reliance on exact jitter.
                     outage_pause_secs: 1
                   )
                 )

        assert reason =~ "provider outage"
        refute reason =~ "consecutive deterministic failures"
      end)

    assert output =~ "provider outage detected"
    refute output =~ "consecutive deterministic failures"
    # Never touches consecutive_fails/max_retries — the pitch is left
    # untouched in ready/, not parked or skipped.
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    # Ceiling is 1s; the probe never fires again after exhaustion is detected
    # on entry (elapsed_secs=0 < 1 passes once, then the recorded delay from
    # the single :down probe pushes elapsed past the ceiling).
    assert length(Agent.get(sleeps, & &1)) == 1
  end

  test "5b: outage-pause sleep stays within +/-20% of the base retry_delays entry (jitter bound)",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    sleeps = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> true end
    probe_fn = fn _state -> :down end
    sleep_fn = fn secs -> Agent.update(sleeps, &(&1 ++ [secs])) end

    capture_io(:stderr, fn ->
      assert {:error, _reason} =
               quiet_drain(
                 base_opts(ctx,
                   spawn_fn: spawn_fn,
                   transient_fn: transient_fn,
                   probe_fn: probe_fn,
                   sleep_fn: sleep_fn,
                   outage_pause_secs: 1
                 )
               )
    end)

    [first_delay] = Agent.get(sleeps, & &1)
    # base = 30 (retry_delays[0], attempt 1); jitter +/-20% -> [24, 36]
    assert first_delay in 24..36, "expected jittered delay in 24..36, got #{first_delay}"
  end

  # ── 6. Deterministic failure -> skip-and-continue (below breaker threshold) ──

  test "6: deterministic failure skips-and-continues, remaining pitches stay in ready/", ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> false end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

    assert File.exists?(Path.join(ctx.ready_dir, "a.md"))
    assert File.exists?(Path.join(ctx.ready_dir, "b.md"))
    assert output =~ "queue: FAILED bucket:"
    assert output =~ "a"
    assert output =~ "b"
  end

  # ── 6b. Consecutive-failure circuit breaker ─────────────────────────────

  test "6b: circuit breaker trips at default threshold (3 consecutive fails)", ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b")
    write_pitch(ctx.ready_dir, "c")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> false end

    assert {:error, reason} =
             quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))

    assert reason =~ "HALTED"
    assert reason =~ "consecutive"
    assert File.exists?(Path.join(ctx.ready_dir, "a.md"))
    assert File.exists?(Path.join(ctx.ready_dir, "b.md"))
    assert File.exists?(Path.join(ctx.ready_dir, "c.md"))
  end

  test "6c: a ship between fails resets the consecutive-fail streak, no trip", ctx do
    # Ordered alphabetically by ordered_fn: a_fail1, b_good, c_fail2, d_fail3
    # — ship at position 2 breaks the fail-streak before it reaches 3.
    write_pitch(ctx.ready_dir, "a_fail1")
    write_pitch(ctx.ready_dir, "b_good")
    write_pitch(ctx.ready_dir, "c_fail2")
    write_pitch(ctx.ready_dir, "d_fail3")

    spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
      if slug == "b_good", do: {:exit_code, 0}, else: {:exit_code, 1}
    end

    transient_fn = fn _jsonl -> false end

    # Only "b_good" (exit 0) must look committed + fresh-clear; the *_fail
    # slugs (nonzero) must NOT — else handle_nonzero_exit/6's
    # post-commit-hiccup branch would ship them anyway.
    # git_head_fn is called TWICE per attempt whenever head_before is
    # non-nil/non-empty (head_before pre-spawn, head_after post-spawn — both
    # handle_nonzero_exit/6 and handle_exit_zero/6 re-read HEAD when
    # known_base? is true): call 0-1 = a_fail1 (before, after), call 2-3 =
    # b_good (before, after — must show a forward move), call 4-5 =
    # c_fail2, call 6-7 = d_fail3 (transient_fn is false, so each
    # deterministic failure skip-and-continues after exactly one attempt —
    # no retries to account for).
    head_calls = start_agent(0)
    gate_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n in [2, 3], do: if(n == 2, do: "aaa", else: "bbb"), else: "zzz"
    end

    # gate_verdict_fn/gate_base_sha_fn are called ONCE per handler invocation
    # (handle_nonzero_exit or handle_exit_zero), immediately after the
    # matching head_before/head_after pair — so their own call sequence
    # mirrors the per-attempt cadence: call 0 = a_fail1 (nonzero), call 1 =
    # b_good (exit 0, the only one that must read "clear"), call 2 =
    # c_fail2 (nonzero), call 3 = d_fail3 (nonzero — never reached because
    # 6c's fail-streak is reset by b_good's ship, so the circuit breaker
    # threshold of 3 is never hit).
    gate_verdict_fn = fn _cwd ->
      n = Agent.get_and_update(gate_calls, fn n -> {n, n + 1} end)
      if n == 1, do: "clear", else: "failed"
    end

    # Gate ran before the commit — base_sha matches b_good's head_before
    # ("aaa"), never head_after ("bbb").
    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end

    assert {:ok, 1} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 transient_fn: transient_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn,
                 gate_base_sha_fn: gate_base_sha_fn,
                 gate_mtime_fn: gate_mtime_fn
               )
             )

    assert File.exists?(Path.join(ctx.ready_dir, "a_fail1.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "b_good.md"))
    assert File.exists?(Path.join(ctx.ready_dir, "c_fail2.md"))
    assert File.exists?(Path.join(ctx.ready_dir, "d_fail3.md"))
  end

  test "6d: custom :max_consecutive_fails trips at the configured threshold", ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> false end

    assert {:error, reason} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 transient_fn: transient_fn,
                 max_consecutive_fails: 2
               )
             )

    assert reason =~ "HALTED"
    assert reason =~ "2 consecutive"
  end

  test "6e: failed pitch is stashed with reason \"fail\" (not \"timeout\")", ctx do
    write_pitch(ctx.ready_dir, "solo")

    stash_calls = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> false end

    git_stash_fn = fn cwd, slug, reason ->
      Agent.update(stash_calls, &(&1 ++ [{cwd, slug, reason}]))
      :ok
    end

    assert {:ok, 0} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 transient_fn: transient_fn,
                 git_stash_fn: git_stash_fn
               )
             )

    assert Agent.get(stash_calls, & &1) == [{ctx.dir, "solo", "fail"}]
  end

  test "6f: fail-then-ship — failed pitch stays in ready/, good ships, FAILED bucket printed",
       ctx do
    write_pitch(ctx.ready_dir, "bad")
    write_pitch(ctx.ready_dir, "good")

    current_slug = start_agent(nil)

    spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
      Agent.update(current_slug, fn _ -> slug end)
      if slug == "bad", do: {:exit_code, 1}, else: {:exit_code, 0}
    end

    transient_fn = fn _jsonl -> false end

    # "bad" (nonzero) must NOT look committed/clear — else
    # handle_nonzero_exit's post-commit-hiccup branch would ship it
    # anyway. "good" (exit 0) needs committed + fresh-clear to ship via
    # handle_exit_zero. current_slug (set by spawn_fn just above) lets
    # git_head_fn/gate_verdict_fn special-case per slug.
    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      if Agent.get(current_slug, & &1) == "bad" do
        "aaa"
      else
        n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
        if rem(n, 2) == 0, do: "aaa", else: "bbb"
      end
    end

    gate_verdict_fn = fn _cwd ->
      if Agent.get(current_slug, & &1) == "bad", do: "failed", else: "clear"
    end

    # Gate ran before the commit — base_sha matches "good"'s head_before
    # ("aaa"), never head_after ("bbb").
    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     git_head_fn: git_head_fn,
                     gate_verdict_fn: gate_verdict_fn,
                     gate_base_sha_fn: gate_base_sha_fn,
                     gate_mtime_fn: gate_mtime_fn
                   )
                 )
      end)

    assert File.exists?(Path.join(ctx.ready_dir, "bad.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "good.md"))
    assert output =~ "queue: FAILED bucket:"
    assert output =~ "bad"
  end

  # ── D. draft_fn — headless failure drafting ─────────────────────────────

  test "D1: nonzero-exit terminal FAILED calls draft_fn once, reports drafted count", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> false end

    calls = start_agent([])

    draft_fn = fn cwd, slug, _jsonl, failure_block ->
      Agent.update(calls, &(&1 ++ [{cwd, slug, failure_block}]))
      {:ok, Path.join(cwd, "codegen/pitches/draft/#{slug}.md")}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     draft_fn: draft_fn
                   )
                 )
      end)

    # Default fixture state (gate_verdict_fn -> "", git_head_fn -> nil, i.e.
    # never committed) classifies as :gate_failed — the not-clear/not-a-crash
    # catch-all — with the raw (empty) verdict preserved verbatim.
    assert [{cwd, slug, failure_block}] = Agent.get(calls, & &1)
    assert cwd == ctx.dir
    assert slug == "solo"
    assert failure_block =~ "Failure cause: gate_failed"
    assert failure_block =~ "Gate verdict: \n"
    assert output =~ "queue: 0 shipped, 1 failed, 1 drafted,"
  end

  test "D2: exit-0-without-verified-commit terminal FAILED calls draft_fn once", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    calls = start_agent([])

    draft_fn = fn cwd, slug, _jsonl, _gate_verdict ->
      Agent.update(calls, &(&1 ++ [slug]))
      {:ok, Path.join(cwd, "codegen/pitches/draft/#{slug}.md")}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     git_head_fn: fn _cwd -> nil end,
                     draft_fn: draft_fn
                   )
                 )
      end)

    assert Agent.get(calls, & &1) == ["solo"]
    assert output =~ "queue: 0 shipped, 1 failed, 1 drafted,"
  end

  test "D3: sustained transient outage HALTs WITHOUT ever calling draft_fn (outage != terminal-fail)",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> true end
    probe_fn = fn _state -> :down end

    calls = start_agent([])

    draft_fn = fn _cwd, slug, _jsonl, _gate_verdict ->
      Agent.update(calls, &(&1 ++ [slug]))
      {:ok, "/dev/null"}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:error, reason} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     probe_fn: probe_fn,
                     outage_pause_secs: 1,
                     max_retries: 2,
                     draft_fn: draft_fn
                   )
                 )

        assert reason =~ "provider outage"
      end)

    # A HALT (any HALT class, including this outage one) never drafts — draft_fn
    # is only ever called from the two terminal-FAILED skip-and-continue arms.
    assert Agent.get(calls, & &1) == []
    assert output =~ "provider outage detected"
  end

  test "D4: HALT arms (infra abort, orphaned base) never call draft_fn", ctx do
    write_pitch(ctx.ready_dir, "solo")

    calls = start_agent([])

    draft_fn = fn _cwd, slug, _jsonl, _gv ->
      Agent.update(calls, &(&1 ++ [slug])) && {:ok, "x"}
    end

    infra_spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 3} end

    capture_io(:stderr, fn ->
      assert {:error, _reason} =
               quiet_drain(base_opts(ctx, spawn_fn: infra_spawn_fn, draft_fn: draft_fn))
    end)

    assert Agent.get(calls, & &1) == []

    # orphaned-base HALT: HEAD moves but is not a descendant of head_before.
    # git_head_fn must return a NEW value each call (pre-spawn head_before,
    # post-spawn head_after) — a constant value never satisfies head_moved?.
    orphan_spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    orphan_head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(orphan_head_calls, fn n -> {n, n + 1} end)
      "head-#{n}"
    end

    git_ancestor_fn = fn _cwd, _ancestor, _descendant -> false end

    capture_io(:stderr, fn ->
      assert {:error, _reason} =
               quiet_drain(
                 base_opts(ctx,
                   spawn_fn: orphan_spawn_fn,
                   git_head_fn: git_head_fn,
                   git_ancestor_fn: git_ancestor_fn,
                   draft_fn: draft_fn
                 )
               )
    end)

    assert Agent.get(calls, & &1) == []
  end

  test "D5: draft_fn error is fail-open — drain continues, count unchanged, loud stderr", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> false end
    draft_fn = fn _cwd, _slug, _jsonl, _gv -> {:error, :boom} end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     draft_fn: draft_fn
                   )
                 )
      end)

    assert output =~ "queue: draft skipped for solo"
    assert output =~ "queue: 0 shipped, 1 failed, 0 drafted,"
  end

  test "D6: default_draft_fn/4 draft scan returns SKELETON, SHAPING, and SHAPED drafts alike",
       ctx do
    draft_dir = Path.join([ctx.dir, "codegen", "pitches", "draft"])
    File.mkdir_p!(draft_dir)

    File.write!(
      Path.join(draft_dir, "skel-one.md"),
      "---\nstatus: SKELETON\n---\n\n## Problem\n\nfoo\n"
    )

    File.write!(
      Path.join(draft_dir, "shaped-one.md"),
      "---\nstatus: SHAPED\n---\n\n## Appetite\n\nbar\n"
    )

    script = Path.join(ctx.dir, "fake_codegen_call.sh")

    File.write!(script, """
    #!/usr/bin/env bash
    echo "$@" > "#{ctx.dir}/call_args.txt"
    cat "#{ctx.dir}/call_prompt.txt" > /dev/null 2>&1 || true
    echo '{"result":{"status":"success","value":{"action":"new","slug":"captured","body":"x"}}}'
    exit 0
    """)

    File.chmod!(script, 0o755)
    Process.put(:__queue_drain_call_bin__, script)
    on_exit(fn -> Process.delete(:__queue_drain_call_bin__) end)

    jsonl = Path.join(ctx.dir, "out.jsonl")
    File.write!(jsonl, ~s({"type":"result","result":"boom"}\n))

    assert {:ok, _path} =
             LoopQueueDrain.default_draft_fn(ctx.dir, "solo", jsonl, "failed")

    args_line = File.read!(Path.join(ctx.dir, "call_args.txt"))
    assert args_line =~ "skel-one"
    assert args_line =~ "shaped-one"
    assert File.exists?(Path.join(draft_dir, "captured.md"))
  end

  test "D6b: default_draft_fn/4 prompt falls back to terminal_reason when result is absent, but prefers result when present",
       ctx do
    script = Path.join(ctx.dir, "fake_codegen_call_terminal.sh")

    File.write!(script, """
    #!/usr/bin/env bash
    echo "$@" > "#{ctx.dir}/call_args.txt"
    echo '{"result":{"status":"success","value":{"action":"new","slug":"captured2","body":"x"}}}'
    exit 0
    """)

    File.chmod!(script, 0o755)
    Process.put(:__queue_drain_call_bin__, script)
    on_exit(fn -> Process.delete(:__queue_drain_call_bin__) end)

    # Leg A: envelope with NO `result` key — falls back to terminal_reason/subtype.
    jsonl_terminal = Path.join(ctx.dir, "terminal.jsonl")

    File.write!(
      jsonl_terminal,
      ~s({"type":"result","subtype":"error","terminal_reason":"loop_failed"}\n)
    )

    assert {:ok, _path} =
             LoopQueueDrain.default_draft_fn(ctx.dir, "solo", jsonl_terminal, "clear")

    args_a = File.read!(Path.join(ctx.dir, "call_args.txt"))
    assert args_a =~ "terminal: loop_failed (error)"

    # Leg B: envelope WITH a `result` string — preferred over terminal_reason.
    jsonl_result = Path.join(ctx.dir, "result.jsonl")

    File.write!(
      jsonl_result,
      ~s({"type":"result","result":"boom","terminal_reason":"loop_failed"}\n)
    )

    assert {:ok, _path} = LoopQueueDrain.default_draft_fn(ctx.dir, "solo", jsonl_result, "clear")

    args_b = File.read!(Path.join(ctx.dir, "call_args.txt"))
    assert args_b =~ "boom"
    refute args_b =~ "terminal: loop_failed"
  end

  test "D7: merge rejects an unlisted target_slug — on-disk drafts unchanged", ctx do
    draft_dir = Path.join([ctx.dir, "codegen", "pitches", "draft"])
    File.mkdir_p!(draft_dir)

    # A SHAPED draft is now a LEGAL merge target (widened population) — use a
    # target_slug that names NO on-disk draft at all to exercise the reject path.
    shaped_path = Path.join(draft_dir, "shaped-one.md")
    shaped_body = "---\nstatus: SHAPED\n---\n\n## Appetite\n\nbar\n"
    File.write!(shaped_path, shaped_body)

    script = Path.join(ctx.dir, "fake_codegen_call_bad_merge.sh")

    File.write!(script, """
    #!/usr/bin/env bash
    echo '{"result":{"status":"success","value":{"action":"merge","target_slug":"nonexistent-slug","slug":"x","body":"overwritten"}}}'
    exit 0
    """)

    File.chmod!(script, 0o755)
    Process.put(:__queue_drain_call_bin__, script)
    on_exit(fn -> Process.delete(:__queue_drain_call_bin__) end)

    jsonl = Path.join(ctx.dir, "out.jsonl")
    File.write!(jsonl, ~s({"type":"result","result":"boom"}\n))

    assert {:error, reason} = LoopQueueDrain.default_draft_fn(ctx.dir, "solo", jsonl, "failed")
    assert reason =~ "nonexistent-slug"

    assert File.read!(shaped_path) == shaped_body
  end

  test "D7b: merge into a SKELETON target overwrites the file with the drafter's full merged body",
       ctx do
    draft_dir = Path.join([ctx.dir, "codegen", "pitches", "draft"])
    File.mkdir_p!(draft_dir)

    skel_path = Path.join(draft_dir, "skel-one.md")
    File.write!(skel_path, "---\nstatus: SKELETON\n---\n\n## Problem\n\nfoo\n")

    script = Path.join(ctx.dir, "fake_codegen_call_merge_skeleton.sh")

    File.write!(script, """
    #!/usr/bin/env bash
    echo '{"result":{"status":"success","value":{"action":"merge","target_slug":"skel-one","slug":"x","body":"---\\nstatus: SKELETON\\n---\\n\\n## Problem\\n\\nfoo, plus a new mechanism\\n"}}}'
    exit 0
    """)

    File.chmod!(script, 0o755)
    Process.put(:__queue_drain_call_bin__, script)
    on_exit(fn -> Process.delete(:__queue_drain_call_bin__) end)

    jsonl = Path.join(ctx.dir, "out.jsonl")
    File.write!(jsonl, ~s({"type":"result","result":"boom"}\n))

    assert {:ok, path} = LoopQueueDrain.default_draft_fn(ctx.dir, "solo", jsonl, "failed")
    assert path == skel_path
    assert File.read!(skel_path) =~ "foo, plus a new mechanism"
  end

  test "D7c: merge into a SHAPING/SHAPED target FOLDS the note — never overwrites committed frontmatter/body",
       ctx do
    draft_dir = Path.join([ctx.dir, "codegen", "pitches", "draft"])
    File.mkdir_p!(draft_dir)

    shaping_path = Path.join(draft_dir, "shaping-one.md")

    shaping_body =
      "---\nstatus: SHAPING\nsummary: >\n  Load-bearing summary text.\nblocks_on: []\n---\n\n" <>
        "## Problem\n\nOriginal problem prose.\n\n## Claim ledger\n\n| # | Claim |\n"

    File.write!(shaping_path, shaping_body)

    script = Path.join(ctx.dir, "fake_codegen_call_merge_shaping.sh")

    File.write!(script, """
    #!/usr/bin/env bash
    echo '{"result":{"status":"success","value":{"action":"merge","target_slug":"shaping-one","slug":"x","body":"A second queue-drain failure hit the same invariant."}}}'
    exit 0
    """)

    File.chmod!(script, 0o755)
    Process.put(:__queue_drain_call_bin__, script)
    on_exit(fn -> Process.delete(:__queue_drain_call_bin__) end)

    jsonl = Path.join(ctx.dir, "out.jsonl")
    File.write!(jsonl, ~s({"type":"result","result":"boom"}\n))

    assert {:ok, path} = LoopQueueDrain.default_draft_fn(ctx.dir, "solo", jsonl, "failed")
    assert path == shaping_path

    merged = File.read!(shaping_path)
    # Committed frontmatter and existing body prose survive untouched.
    assert merged =~ "status: SHAPING"
    assert merged =~ "summary: >"
    assert merged =~ "Load-bearing summary text."
    assert merged =~ "blocks_on: []"
    assert merged =~ "Original problem prose."
    assert merged =~ "## Claim ledger"
    # The note is folded on, not used to replace the file.
    assert merged =~ "A second queue-drain failure hit the same invariant."
  end

  # ── D8-D11. classify_drain_failure — true-cause labeling ─────────────────
  # Regression coverage for "the-guard-parses-quotes-worse-than-the-shell-it-
  # guards": a retry-exhausted/false-exit-0 skeleton must never present as a
  # bare, unqualified `clear` verdict — the drafted failure block must always
  # name a true cause.

  test "D8: exit-0, gate fresh-clear, HEAD never moved -> classifies ship_not_verified, stamps STALE marker, warns on stderr",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    # HEAD never advances (before == after) -> known_base? true, head_moved?
    # false -> committed? false, while the gate reads fresh-clear. Must NOT
    # be a real transient (a killed/crashed child with no result record) --
    # explicitly false, since exit-0 classification now reads transient_fn.
    transient_fn = fn _jsonl -> false end
    git_head_fn = fn _cwd -> "aaa" end
    gate_verdict_fn = fn _cwd -> "clear" end
    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end

    calls = start_agent([])

    draft_fn = fn _cwd, slug, _jsonl, failure_block ->
      Agent.update(calls, &(&1 ++ [{slug, failure_block}]))
      {:ok, "/dev/null"}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     git_head_fn: git_head_fn,
                     gate_verdict_fn: gate_verdict_fn,
                     gate_base_sha_fn: gate_base_sha_fn,
                     gate_mtime_fn: gate_mtime_fn,
                     draft_fn: draft_fn
                   )
                 )
      end)

    assert [{"solo", failure_block}] = Agent.get(calls, & &1)
    assert failure_block =~ "Failure cause: ship_not_verified"
    assert failure_block =~ "HEAD did not advance"
    # The raw on-disk verdict IS "clear" -- the block must qualify it, never
    # present an unqualified "Gate verdict: clear" that reads as clean.
    refute failure_block =~ "Gate verdict: clear\n"
    assert failure_block =~ "Gate verdict: clear (ship not verified — HEAD did not advance)"

    assert output =~
             "queue: WARN — solo classified ship_not_verified but raw gate verdict on disk reads \"clear\""
  end

  test "D9: exit-0-without-verified-commit, transient_fn true (child produced no result record) -> classifies transient_exhausted",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    # Exit-0 path: no verified commit (git_head_fn nil -> committed? false)
    # AND the drafter's own transient probe reads true (a killed/crashed
    # child left no result record) -- the exact condition the pitch names
    # as the retry-exhaustion root cause. transient? is checked FIRST in
    # classify_drain_failure/1, ahead of ship_not_verified.
    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    transient_fn = fn _jsonl -> true end

    calls = start_agent([])

    draft_fn = fn _cwd, slug, _jsonl, failure_block ->
      Agent.update(calls, &(&1 ++ [{slug, failure_block}]))
      {:ok, "/dev/null"}
    end

    capture_io(:stderr, fn ->
      assert {:ok, 0} =
               quiet_drain(
                 base_opts(ctx,
                   spawn_fn: spawn_fn,
                   transient_fn: transient_fn,
                   git_head_fn: fn _cwd -> nil end,
                   draft_fn: draft_fn
                 )
               )
    end)

    assert [{"solo", failure_block}] = Agent.get(calls, & &1)
    assert failure_block =~ "Failure cause: transient_exhausted"
    assert failure_block =~ "retried 0×"
  end

  test "D9b: transient_fn true PAIRED with a genuinely fresh clear gate verdict -> block still qualifies, never bare unqualified clear",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    # The sibling gap to D8: transient? true (child produced no result
    # record) co-occurring with a gate that IS fresh-clear for this cycle
    # (fresh gate_base_sha_fn/gate_mtime_fn, matching git_head_fn — same
    # freshness shape D8 uses for ship_not_verified). classify_drain_failure/1
    # checks transient? FIRST, so this classifies transient_exhausted even
    # though gate_clear? is true -- format_failure_block/3 must qualify the
    # bare "clear" for THIS cause atom too, not only :ship_not_verified.
    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    transient_fn = fn _jsonl -> true end
    git_head_fn = fn _cwd -> "aaa" end
    gate_verdict_fn = fn _cwd -> "clear" end
    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end

    calls = start_agent([])

    draft_fn = fn _cwd, slug, _jsonl, failure_block ->
      Agent.update(calls, &(&1 ++ [{slug, failure_block}]))
      {:ok, "/dev/null"}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     git_head_fn: git_head_fn,
                     gate_verdict_fn: gate_verdict_fn,
                     gate_base_sha_fn: gate_base_sha_fn,
                     gate_mtime_fn: gate_mtime_fn,
                     draft_fn: draft_fn
                   )
                 )
      end)

    assert [{"solo", failure_block}] = Agent.get(calls, & &1)
    assert failure_block =~ "Failure cause: transient_exhausted"
    # The invariant this fixture pins: an unqualified "Gate verdict: clear\n"
    # must NEVER appear, regardless of which of the two causes produced it.
    refute failure_block =~ "Gate verdict: clear\n"

    assert failure_block =~
             "Gate verdict: clear (transient — child produced no result record this cycle)"

    assert output =~
             "queue: WARN — solo classified transient_exhausted but raw gate verdict on disk reads \"clear\""
  end

  test "D10: genuine gate failed verdict, not committed -> classifies gate_failed, preserves verdict verbatim",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> false end
    gate_verdict_fn = fn _cwd -> "failed" end

    calls = start_agent([])

    draft_fn = fn _cwd, slug, _jsonl, failure_block ->
      Agent.update(calls, &(&1 ++ [{slug, failure_block}]))
      {:ok, "/dev/null"}
    end

    capture_io(:stderr, fn ->
      assert {:ok, 0} =
               quiet_drain(
                 base_opts(ctx,
                   spawn_fn: spawn_fn,
                   transient_fn: transient_fn,
                   gate_verdict_fn: gate_verdict_fn,
                   draft_fn: draft_fn
                 )
               )
    end)

    assert [{"solo", failure_block}] = Agent.get(calls, & &1)
    assert failure_block =~ "Failure cause: gate_failed"
    assert failure_block =~ "gate verdict=\"failed\""
    assert failure_block =~ "Gate verdict: failed\n"
  end

  test "D11: invariant — no drafted failure block ever shows an unqualified clear verdict without naming a non-clear cause",
       _ctx do
    fixtures = [
      # {spawn_exit, transient?, gate_verdict, git_head_fn, extra_opts}
      {0, false, "clear", fn _cwd -> "aaa" end,
       [gate_base_sha_fn: fn _cwd -> "aaa" end, gate_mtime_fn: fn _cwd -> 1_700_000_000 end]},
      # exit-0 (not nonzero): transient_fn=true at the NONZERO arm always
      # routes through the outage-pause path first (never reaching the
      # terminal-FAILED catch-all) -- the exit-0 arm has no such detour.
      {0, true, "", fn _cwd -> nil end, []},
      {1, false, "failed", fn _cwd -> nil end, []}
    ]

    # Each fixture drives its own isolated tmp dir via the existing setup
    # contract (ready_dir/shipped_dir/lock_path) -- one drain per fixture.
    for {exit_code, transient?, gate_verdict, git_head_fn, extra} <- fixtures do
      dir =
        Path.join(
          System.tmp_dir!(),
          "loop_queue_drain_d11_#{:erlang.unique_integer([:positive])}"
        )

      ready_dir = Path.join([dir, "codegen", "pitches", "ready"])
      shipped_dir = Path.join([dir, "codegen", "pitches", "shipped"])
      lock_path = Path.join([dir, "codegen", "pitches", "queue.lock"])
      File.mkdir_p!(ready_dir)
      File.mkdir_p!(shipped_dir)

      write_pitch(ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, exit_code} end
      transient_fn = fn _jsonl -> transient? end
      gate_verdict_fn = fn _cwd -> gate_verdict end

      calls = start_agent([])

      draft_fn = fn _cwd, slug, _jsonl, failure_block ->
        Agent.update(calls, &(&1 ++ [{slug, failure_block}]))
        {:ok, "/dev/null"}
      end

      capture_io(:stderr, fn ->
        quiet_drain(
          base_opts(
            %{dir: dir, ready_dir: ready_dir, shipped_dir: shipped_dir, lock_path: lock_path},
            Keyword.merge(
              [
                spawn_fn: spawn_fn,
                transient_fn: transient_fn,
                gate_verdict_fn: gate_verdict_fn,
                git_head_fn: git_head_fn,
                draft_fn: draft_fn
              ],
              extra
            )
          )
        )
      end)

      assert [{"solo", failure_block}] = Agent.get(calls, & &1)
      assert failure_block =~ "Failure cause:"

      # The invariant: an unqualified "Gate verdict: clear\n" never appears
      # on a drafted (i.e. terminal-FAILED) block -- a fresh clear +
      # committed cycle ships rather than drafting, so any drafted block
      # whose raw verdict reads "clear" must carry a qualifier: either
      # genuinely STALE (an earlier cycle's leftover) or fresh-but the ship
      # itself was never verified.
      if gate_verdict == "clear" do
        refute failure_block =~ "Gate verdict: clear\n"
        assert failure_block =~ "STALE" or failure_block =~ "ship not verified"
      end

      File.rm_rf!(dir)
    end
  end

  # ── Auto-demotion after repeated deterministic failure ──────────────────

  describe "auto-demotion after repeated deterministic failure" do
    test "first deterministic failure increments build_failures, pitch stays in ready/", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> false end

      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

      ready_path = Path.join(ctx.ready_dir, "solo.md")
      assert File.exists?(ready_path)
      body = File.read!(ready_path)
      assert body =~ "build_failures: 1"
      # A durable evidence row is written on the FIRST counted deterministic
      # failure too — not only at demotion.
      assert body =~ "## Build failure history"
      assert body =~ "| queue drain |"
      assert body =~ "cause=gate_failed"
    end

    test "second deterministic failure demotes to draft/ with full history", ctx do
      # Seed a FIRST row too (as write_build_failures!/3 would have left it)
      # so this test asserts BOTH rows survive demotion in order, not just
      # the counter.
      write_pitch(
        ctx.ready_dir,
        "solo",
        "---\nbuild_failures: 1\nblocks_on: []\n---\n\n# Pitch: solo\n\n" <>
          "## Build failure history\n\n| run | when | cost | terminal reason |\n" <>
          "|---|---|---|---|\n" <>
          "| queue drain | 2023-11-14T00:00:00Z | unaccountable | cause=gate_failed; owner=drain/gate; detail=first failure; recovery=none (tree clean); raw=codegen/logging/first.log |\n"
      )

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> false end

      output =
        capture_io(:stderr, fn ->
          assert {:ok, 0} =
                   quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
        end)

      ready_path = Path.join(ctx.ready_dir, "solo.md")
      draft_path = Path.join([ctx.dir, "codegen", "pitches", "draft", "solo.md"])

      refute File.exists?(ready_path)
      assert File.exists?(draft_path)

      body = File.read!(draft_path)
      assert body =~ "build_failures: 2"
      assert body =~ "demoted_from: ready"
      assert body =~ "demote_reason: deterministic-build-failure-x2"
      assert body =~ "status: SHAPING"
      assert body =~ "## Build failure history"

      # Both rows present, in chronological order (first row seeded above,
      # second row appended by this run).
      rows = body |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| queue drain"))
      assert length(rows) == 2
      assert Enum.at(rows, 0) =~ "first failure"
      refute Enum.at(rows, 1) =~ "first failure"

      assert output =~ "queue: DEMOTED solo after 2 deterministic failures"
    end

    test "transient failure does not increment build_failures", ctx do
      write_pitch(ctx.ready_dir, "solo")

      # Sustained transient outage (probe never recovers) HALTs quickly under
      # a small outage_pause_secs — the point here is only that the HALT
      # path never increments build_failures, not the eventual outcome.
      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> true end
      probe_fn = fn _state -> :down end

      capture_io(:stderr, fn ->
        assert {:error, reason} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     probe_fn: probe_fn,
                     outage_pause_secs: 1
                   )
                 )

        assert reason =~ "provider outage"
      end)

      ready_path = Path.join(ctx.ready_dir, "solo.md")
      assert File.exists?(ready_path)
      refute File.read!(ready_path) =~ "build_failures:"
    end

    test "false-exit-0 arm increments build_failures", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     git_head_fn: fn _cwd -> nil end
                   )
                 )
      end)

      ready_path = Path.join(ctx.ready_dir, "solo.md")
      assert File.exists?(ready_path)
      assert File.read!(ready_path) =~ "build_failures: 1"
    end

    test "terminal-marker arm increments build_failures", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> true end

      terminal_marker_fn = fn _cwd ->
        {:terminal, "gate verdict=failed", "developer-phoenix-backend"}
      end

      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     terminal_marker_fn: terminal_marker_fn
                   )
                 )
      end)

      ready_path = Path.join(ctx.ready_dir, "solo.md")
      assert File.exists?(ready_path)
      assert File.read!(ready_path) =~ "build_failures: 1"
    end

    test "a pitch stranded in building/ only (crashed child, never restored to ready/) resolves via resolve_pitch_path's ready-then-building probe",
         ctx do
      building_dir = Path.join([ctx.dir, "codegen", "pitches", "building"])
      File.mkdir_p!(building_dir)

      # NOT written to ready_dir — simulates a crashed child that never ran
      # restore_claim/2, leaving the slug stranded in building_dir only (see
      # moduledoc "A crashed build strands its slug in `building_dir`
      # indefinitely"). The drain never spawns this slug (it isn't in
      # ready_dir to be selected) — this exercises resolve_pitch_path/2 and
      # write_demotion!/5 DIRECTLY against the building/-only shape via the
      # module's own public LoopQueue helpers, since the drain itself has no
      # way to re-select an already-claimed slug.
      building_path = Path.join(building_dir, "solo.md")

      File.write!(
        building_path,
        "---\nbuild_failures: 1\nblocks_on: []\n---\n\n# Pitch: solo\n"
      )

      draft_path = Path.join([ctx.dir, "codegen", "pitches", "draft", "solo.md"])

      CodegenTestHarness.LoopQueue.write_demotion!(
        building_path,
        draft_path,
        2,
        "| queue drain | 123 | n/a | deterministic failure #2 |",
        "Build failure history"
      )

      refute File.exists?(building_path)
      assert File.exists?(draft_path)
      assert File.read!(draft_path) =~ "build_failures: 2"
    end

    test "demotion names stranded dependents in the cascade message", ctx do
      write_pitch(
        ctx.ready_dir,
        "a",
        "---\nbuild_failures: 1\nblocks_on: []\n---\n\n# Pitch: a\n"
      )

      write_pitch(ctx.ready_dir, "b", "---\nblocks_on: [a]\n---\n\n# Pitch: b\n")

      spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
        if slug == "a", do: {:exit_code, 1}, else: {:exit_code, 0}
      end

      transient_fn = fn _jsonl -> false end

      output =
        capture_io(:stderr, fn ->
          quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
        end)

      assert output =~ "queue: DEMOTED a after 2 deterministic failures"
      assert output =~ "blocked: b"
    end

    test "env override raises the threshold (custom :max_pitch_fails)", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> false end

      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     max_pitch_fails: 5
                   )
                 )
      end)

      ready_path = Path.join(ctx.ready_dir, "solo.md")
      assert File.exists?(ready_path)
      assert File.read!(ready_path) =~ "build_failures: 1"
    end

    test "demoted pitch's frontmatter still parses via LoopQueue.parse_edges/2", ctx do
      # "some-dep" must already be SATISFIED (present in shipped_dir) —
      # reblock_for_exclude/3 always recomputes blocked_by_unmet_dep for
      # real (its `map_size(exclude) == 0` guard never actually matches a
      # MapSet, a pre-existing quirk unrelated to this pitch), so an
      # edge to a genuinely-unmet dep would land "solo" in the SKIPPED
      # (unmet dep) bucket instead of ever being spawned/failed/demoted.
      write_pitch(ctx.shipped_dir, "some-dep")

      write_pitch(
        ctx.ready_dir,
        "solo",
        "---\nbuild_failures: 1\nblocks_on: [some-dep]\n---\n\n# Pitch: solo\n"
      )

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> false end

      capture_io(:stderr, fn ->
        quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

      draft_path = Path.join([ctx.dir, "codegen", "pitches", "draft", "solo.md"])

      assert CodegenTestHarness.LoopQueue.parse_edges("solo", draft_path) == [
               {"solo", "some-dep"}
             ]
    end

    test "no-trailing-newline pitch body demotes without corrupting the history section", ctx do
      body = "---\nbuild_failures: 1\nblocks_on: []\n---\n\n# Pitch: solo (no trailing newline)"
      write_pitch(ctx.ready_dir, "solo", body)

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> false end

      capture_io(:stderr, fn ->
        quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

      draft_path = Path.join([ctx.dir, "codegen", "pitches", "draft", "solo.md"])
      draft_body = File.read!(draft_path)

      assert draft_body =~ "# Pitch: solo (no trailing newline)\n\n## Build failure history"
    end
  end

  describe "handoffs:/handoff_receipt: byte preservation across lifecycle writers" do
    test "write_build_failures!/3 preserves neighboring handoffs:/handoff_receipt: keys", ctx do
      path = Path.join(ctx.ready_dir, "solo.md")

      File.write!(
        path,
        "---\nstatus: SHAPED\nhandoffs: [d::solo::other::lib/x.ex]\nhandoff_receipt: sha256:#{String.duplicate("a", 64)}\n---\n# solo\n"
      )

      CodegenTestHarness.LoopQueue.write_build_failures!(path, 1, "| 1 | fail |")

      updated = File.read!(path)
      assert updated =~ "handoffs: [d::solo::other::lib/x.ex]"
      assert updated =~ "handoff_receipt: sha256:#{String.duplicate("a", 64)}"
    end

    test "write_demotion!/5 preserves neighboring handoffs:/handoff_receipt: keys", ctx do
      ready_path = Path.join(ctx.ready_dir, "solo.md")
      draft_path = Path.join([ctx.dir, "codegen", "pitches", "draft", "solo.md"])

      File.write!(
        ready_path,
        "---\nstatus: SHAPED\nhandoffs: [d::solo::other::lib/x.ex]\nhandoff_receipt: sha256:#{String.duplicate("a", 64)}\n---\n# solo\n"
      )

      CodegenTestHarness.LoopQueue.write_demotion!(
        ready_path,
        draft_path,
        2,
        "| 2 | fail |",
        "Build failure history"
      )

      updated = File.read!(draft_path)
      assert updated =~ "handoffs: [d::solo::other::lib/x.ex]"
      assert updated =~ "handoff_receipt: sha256:#{String.duplicate("a", 64)}"
    end
  end

  describe "build failure evidence rows" do
    test "false-0 arm's row carries drain/ship-verification owner", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

      capture_io(:stderr, fn ->
        quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, git_head_fn: fn _cwd -> nil end))
      end)

      body = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      assert body =~ "owner=drain/ship-verification"
    end

    test "terminal-marker arm's row carries the terminal marker's own owner", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> true end

      terminal_marker_fn = fn _cwd ->
        {:terminal, "gate verdict=failed", "developer-phoenix-backend"}
      end

      capture_io(:stderr, fn ->
        quiet_drain(
          base_opts(ctx,
            spawn_fn: spawn_fn,
            transient_fn: transient_fn,
            terminal_marker_fn: terminal_marker_fn
          )
        )
      end)

      body = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      assert body =~ "owner=developer-phoenix-backend"
    end

    test "general catch-all arm's row carries drain/gate owner", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> false end

      capture_io(:stderr, fn ->
        quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

      body = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      assert body =~ "owner=drain/gate"
    end

    test "fresh gate record includes the witness in the row", ctx do
      write_pitch(ctx.ready_dir, "solo")

      gate_pending_dir = Path.join([ctx.dir, "codegen", "gate-pending"])
      File.mkdir_p!(gate_pending_dir)

      File.write!(
        Path.join(gate_pending_dir, "gate-result.json"),
        ~s({"verdict":"failed","witness":"test/x_test.exs:42 — expected true"})
      )

      # HEAD never moves ("aaa" both before/after) — committed? stays false
      # even though the gate record is fresh-"clear", landing in the
      # general catch-all (gate_clear? true, committed? false ==
      # :ship_not_verified) rather than a ship branch.
      git_head_fn = fn _cwd -> "aaa" end

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> false end
      gate_verdict_fn = fn _cwd -> "clear" end
      gate_base_sha_fn = fn _cwd -> "aaa" end
      gate_mtime_fn = fn _cwd -> 1_700_000_000 end

      capture_io(:stderr, fn ->
        quiet_drain(
          base_opts(ctx,
            spawn_fn: spawn_fn,
            transient_fn: transient_fn,
            git_head_fn: git_head_fn,
            gate_verdict_fn: gate_verdict_fn,
            gate_base_sha_fn: gate_base_sha_fn,
            gate_mtime_fn: gate_mtime_fn
          )
        )
      end)

      body = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      assert body =~ "witness=test/x_test.exs:42 — expected true"
    end

    test "stale gate record omits the witness, uses classified cause + terminal summary instead",
         ctx do
      write_pitch(ctx.ready_dir, "solo")

      gate_pending_dir = Path.join([ctx.dir, "codegen", "gate-pending"])
      File.mkdir_p!(gate_pending_dir)

      File.write!(
        Path.join(gate_pending_dir, "gate-result.json"),
        ~s({"verdict":"failed","witness":"test/x_test.exs:42 — expected true"})
      )

      spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
        File.write!(jsonl, ~s({"type":"result","result":"boom"}\n))
        {:exit_code, 1}
      end

      transient_fn = fn _jsonl -> false end
      # gate_mtime_fn stays at base_opts' default (0) — always stale.

      capture_io(:stderr, fn ->
        quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

      body = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      refute body =~ "witness=test/x_test.exs:42"
      assert body =~ "detail=gate verdict="
      assert body =~ "boom"
    end

    test "nil cost reads unaccountable, never 0 or n/a", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> false end

      capture_io(:stderr, fn ->
        quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

      body = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      row = body |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| queue drain"))
      assert row =~ "| unaccountable |"
      refute row =~ "| 0 |"
      refute row =~ "| n/a |"
    end

    test "accountable cost is recorded in the cost cell", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
        File.write!(jsonl, ~s({"type":"result","total_cost_usd":1.5}\n))
        {:exit_code, 1}
      end

      transient_fn = fn _jsonl -> false end

      capture_io(:stderr, fn ->
        quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

      body = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      row = body |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| queue drain"))
      assert row =~ "| 1.5 |"
    end

    test "clean tree (no parked branch) reads recovery=none (tree clean)", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> false end
      git_stash_fn = fn _cwd, _slug, _reason -> {:ok, nil} end

      capture_io(:stderr, fn ->
        quiet_drain(
          base_opts(ctx,
            spawn_fn: spawn_fn,
            transient_fn: transient_fn,
            git_stash_fn: git_stash_fn
          )
        )
      end)

      body = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      assert body =~ "recovery=none (tree clean)"
    end

    test "a parked branch is named in the recovery cell", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> false end
      git_stash_fn = fn _cwd, slug, _reason -> {:ok, "queue-fail/#{slug}/123"} end

      capture_io(:stderr, fn ->
        quiet_drain(
          base_opts(ctx,
            spawn_fn: spawn_fn,
            transient_fn: transient_fn,
            git_stash_fn: git_stash_fn
          )
        )
      end)

      body = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      assert body =~ "recovery=queue-fail/solo/123"
    end

    test "a terminal reason with a pipe and a newline still yields exactly four cells", ctx do
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
        File.write!(jsonl, ~s({"type":"result","result":"line one | pipe\\nline two"}\n))
        {:exit_code, 1}
      end

      transient_fn = fn _jsonl -> false end

      capture_io(:stderr, fn ->
        quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

      body = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      row = body |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| queue drain"))
      # The row is still exactly 4 STRUCTURAL columns: the embedded pipe is
      # ESCAPED (`\|`, not a raw column-separating `|`), so a literal split
      # on the raw `|` byte cannot be used to count columns (an escaped
      # pipe still contains that byte). Assert structurally instead: the
      # row starts/ends with the 4-column skeleton and the embedded pipe
      # survived escaped, not as a 5th raw column boundary.
      assert row =~ ~r/^\| queue drain \| [^|]+ \| [^|]+ \| .*\\\| pipe.*\|$/
      assert row =~ "line one \\| pipe line two"
      refute row =~ "line one | pipe"
    end

    # Oversized model prose must never grow the pitch file unbounded.
    test "an oversized summary is truncated with a raw-path marker; cause/witness untruncated",
         ctx do
      write_pitch(ctx.ready_dir, "solo")

      long_result = String.duplicate("x", 600)

      spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
        File.write!(jsonl, Jason.encode!(%{"type" => "result", "result" => long_result}) <> "\n")
        {:exit_code, 1}
      end

      transient_fn = fn _jsonl -> false end

      capture_io(:stderr, fn ->
        quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

      body = File.read!(Path.join(ctx.ready_dir, "solo.md"))
      row = body |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| queue drain"))
      assert row =~ "… [truncated; raw="
      assert row =~ "cause=gate_failed; owner=drain/gate"
      refute row =~ String.duplicate("x", 600)
    end

    test "pitch whose history section is followed by ## Problem gets its new row inside the table",
         ctx do
      write_pitch(
        ctx.ready_dir,
        "solo",
        "---\nbuild_failures: 1\nblocks_on: []\n---\n\n# Pitch: solo\n\n" <>
          "## Build failure history\n\n| run | when | cost | terminal reason |\n" <>
          "|---|---|---|---|\n" <>
          "| queue drain | 2023-11-14T00:00:00Z | unaccountable | cause=gate_failed; owner=drain/gate; detail=first failure; recovery=none (tree clean); raw=codegen/logging/first.log |\n\n" <>
          "## Problem\nbody text after history section\n"
      )

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
      transient_fn = fn _jsonl -> false end

      capture_io(:stderr, fn ->
        quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

      draft_path = Path.join([ctx.dir, "codegen", "pitches", "draft", "solo.md"])
      body = File.read!(draft_path)

      rows = body |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| queue drain"))
      assert length(rows) == 2

      problem_at = :binary.match(body, "## Problem") |> elem(0)
      new_row_at = :binary.match(body, "cause=gate_failed; owner=drain/gate; detail=") |> elem(0)
      first_row_at = :binary.match(body, "first failure") |> elem(0)

      assert first_row_at < problem_at
      assert new_row_at < problem_at
      assert body =~ "body text after history section"
    end

    @tag :evidence_persistence_failure
    test "persistence failure halts the drain and stops further spawns", ctx do
      write_pitch(ctx.ready_dir, "solo")
      # "second" depends on "solo" — guarantees deterministic spawn order
      # (solo first) regardless of directory listing order, and confirms
      # the halt happens BEFORE any dependent pitch is ever considered.
      write_pitch(ctx.ready_dir, "second", "---\nblocks_on: [solo]\n---\n\n# Pitch: second\n")

      spawn_calls = start_agent([])

      spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
        Agent.update(spawn_calls, fn calls -> calls ++ [slug] end)

        if slug == "solo" do
          # Force resolve_pitch_path/2 to find a path whose FILE EXISTS
          # (so record_build_failure/3 attempts the write) but whose
          # containing directory then gets removed mid-flight, making the
          # actual File.write! fail with a real I/O error.
          File.rm_rf!(Path.join(ctx.ready_dir, "solo.md"))
          File.mkdir_p!(Path.join(ctx.ready_dir, "solo.md"))
        end

        {:exit_code, 1}
      end

      transient_fn = fn _jsonl -> false end

      output =
        capture_io(:stderr, fn ->
          assert {:error, reason} =
                   quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))

          assert reason =~
                   "queue: HALTED — could not persist failure evidence for solo"
        end)

      _ = output
      assert Agent.get(spawn_calls, & &1) == ["solo"]
    end
  end

  # ── 6r. Committer-post-commit-hiccup recovery ───────────────────────────

  test "6r1: committed + gate-clear + already-in-shipped counts shipped, no re-ship", ctx do
    write_pitch(ctx.ready_dir, "solo")

    head_calls = start_agent([])

    git_head_fn = fn cwd ->
      n = Agent.get_and_update(head_calls, fn calls -> {length(calls), calls ++ [cwd]} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    spawn_fn = fn slug, _h, _s, cwd, _jsonl ->
      # simulate the agent's own commit step having already shipped the pitch
      # (ready/<slug>.md -> shipped/<slug>.md) before the post-commit hiccup
      File.rename!(
        Path.join(ctx.ready_dir, "#{slug}.md"),
        Path.join(ctx.shipped_dir, "#{slug}.md")
      )

      _ = cwd
      {:exit_code, 1}
    end

    gate_verdict_fn = fn _cwd -> "clear" end
    # Gate ran before the commit — base_sha matches head_before ("aaa"), and
    # the record must be fresh (mtime >= spawn ts).
    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end

    assert {:ok, 1} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn,
                 gate_base_sha_fn: gate_base_sha_fn,
                 gate_mtime_fn: gate_mtime_fn
               )
             )

    assert Agent.get(head_calls, & &1) == [ctx.dir, ctx.dir]
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "6r2: committed + gate-clear + still-in-ready finishes the ship", ctx do
    write_pitch(ctx.ready_dir, "solo")

    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    gate_verdict_fn = fn _cwd -> "clear" end
    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end

    assert {:ok, 1} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn,
                 gate_base_sha_fn: gate_base_sha_fn,
                 gate_mtime_fn: gate_mtime_fn
               )
             )

    refute File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "6r3: gate-clear + HEAD-unmoved-on-1st-attempt retries, ships on 2nd spawn (HEAD moves)",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    attempts = start_agent(0)
    sleeps = start_agent([])
    head_calls = start_agent(0)

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      n = Agent.get_and_update(attempts, fn n -> {n, n + 1} end)

      if n == 0 do
        File.write!(jsonl, "no result record here")
        {:exit_code, 1}
      else
        {:exit_code, 0}
      end
    end

    # HEAD never moves during attempt 1 (both head_before/head_after calls
    # return "aaa" -> committed? stays false -> retry_eligible? fires). On
    # attempt 2 (exit 0) HEAD moves forward aaa -> bbb between head_before
    # (call 2) and head_after (call 3), satisfying
    # handle_exit_zero/7's committed? check.
    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n < 3, do: "aaa", else: "bbb"
    end

    gate_verdict_fn = fn _cwd -> "clear" end
    # Gate ran before the commit — base_sha matches attempt 2's head_before
    # ("aaa"), never head_after ("bbb").
    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end
    transient_fn = fn _jsonl -> false end
    sleep_fn = fn secs -> Agent.update(sleeps, &(&1 ++ [secs])) end

    assert {:ok, 1} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn,
                 gate_base_sha_fn: gate_base_sha_fn,
                 gate_mtime_fn: gate_mtime_fn,
                 transient_fn: transient_fn,
                 sleep_fn: sleep_fn
               )
             )

    assert Agent.get(attempts, & &1) == 2
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "6r4: gate-failed + nonzero + HEAD-moved skips-and-continues, stays in ready/", ctx do
    write_pitch(ctx.ready_dir, "solo")

    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    gate_verdict_fn = fn _cwd -> "failed" end
    transient_fn = fn _jsonl -> false end

    assert {:ok, 0} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn,
                 transient_fn: transient_fn
               )
             )

    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
  end

  test "6r5: not-a-repo (nil head) + nonzero + non-transient skips-and-continues (isolated)",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> false end

    assert {:ok, 0} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 transient_fn: transient_fn,
                 git_head_fn: fn _cwd -> nil end,
                 gate_verdict_fn: fn _cwd -> "" end
               )
             )

    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
  end

  test "6r-orphan: HEAD moved + gate-clear + NOT an ancestor halts loud (never ships), repo untouched",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    head_calls = start_agent(0)

    # HEAD moved (aaa -> bbb) and gate is clear — without the forward-only
    # fix this would match the post-commit-hiccup branch and ship.
    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    gate_verdict_fn = fn _cwd -> "clear" end
    # bbb does NOT descend from aaa — the orphan condition.
    git_ancestor_fn = fn _cwd, "aaa", "bbb" -> false end

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, reason} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     git_head_fn: git_head_fn,
                     gate_verdict_fn: gate_verdict_fn,
                     git_ancestor_fn: git_ancestor_fn
                   )
                 )

        assert reason =~ "orphaned base"
      end)

    assert stderr =~ "git rebase --onto aaa bbb^ HEAD"
    # Repo untouched: pitch stays in ready/, never moved to shipped/.
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    refute File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "infra-abort exit code (3) HALTS the drain immediately — no stash, no skip-and-continue",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    stash_calls = start_agent([])

    git_stash_fn = fn _cwd, slug, reason ->
      Agent.update(stash_calls, fn calls -> calls ++ [{slug, reason}] end)
      :ok
    end

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 3} end

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, reason} =
                 quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn))

        assert reason =~ "HALTED"
        assert reason =~ "infra abort"
      end)

    assert stderr =~ "codegen.loop: FAILED" or stderr != ""
    # never stashed — a stash is the deterministic-failure/timeout path only.
    assert Agent.get(stash_calls, & &1) == []
    # pitch left untouched in ready/, never marked failed-and-skipped.
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    refute File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "a second pitch behind an infra abort never runs — the drain halts on the first", ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b")

    spawn_calls = start_agent([])

    spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
      Agent.update(spawn_calls, fn calls -> calls ++ [slug] end)
      {:exit_code, 3}
    end

    capture_io(:stderr, fn ->
      assert {:error, _reason} = quiet_drain(base_opts(ctx, spawn_fn: spawn_fn))
    end)

    assert Agent.get(spawn_calls, & &1) == ["a"]
  end

  test "6r-forward: HEAD moved + gate-clear + IS an ancestor still ships (forward-commit control)",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    gate_verdict_fn = fn _cwd -> "clear" end
    # Gate ran before the commit — base_sha matches head_before ("aaa").
    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end
    # bbb DOES descend from aaa — a legitimate forward commit.
    git_ancestor_fn = fn _cwd, "aaa", "bbb" -> true end

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end

    assert {:ok, 1} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn,
                 gate_base_sha_fn: gate_base_sha_fn,
                 gate_mtime_fn: gate_mtime_fn,
                 git_ancestor_fn: git_ancestor_fn
               )
             )

    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "6r6: transient nonzero retries, then exit-0 with unknown git state (nil head) is treated as FAILED — no unverifiable ship",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    attempts = start_agent(0)
    head_calls = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      n = Agent.get_and_update(attempts, fn n -> {n, n + 1} end)

      if n == 0 do
        File.write!(jsonl, "no result record here")
        {:exit_code, 1}
      else
        {:exit_code, 0}
      end
    end

    git_head_fn = fn cwd ->
      Agent.update(head_calls, &(&1 ++ [cwd]))
      nil
    end

    transient_fn = fn _jsonl -> true end

    # Attempt 1 is a transient nonzero exit -> retries. Attempt 2 exits 0,
    # but git_head_fn returns nil throughout (mirrors a not-a-repo / unknown
    # git state) — handle_exit_zero/6 cannot verify a commit landed, so this
    # is correctly treated as a FAILED cycle (never an unverifiable ship),
    # per the pitch's core fix: exit 0 alone is no longer sufficient proof.
    assert {:ok, 0} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 transient_fn: transient_fn
               )
             )

    assert Agent.get(attempts, & &1) == 2
    # git_head_fn called once per run_slug invocation (pre-spawn), never used
    # for a recovery decision since it's always nil here — known_base? false
    # short-circuits the head_after re-read on both the nonzero-exit path
    # (attempt 1) and the exit-0 path (attempt 2).
    assert Agent.get(head_calls, & &1) == [ctx.dir, ctx.dir]
    refute File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
  end

  # ── 6r-fresh. Gate-record freshness (head_before + mtime) ───────────────

  test "6r-fresh-a: exit-0 + clear + sha prefixes head_before + fresh mtime ships",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    gate_verdict_fn = fn _cwd -> "clear" end
    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end

    assert {:ok, 1} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn,
                 gate_base_sha_fn: gate_base_sha_fn,
                 gate_mtime_fn: gate_mtime_fn
               )
             )

    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "6r-fresh-b: exit-0 + clear + correct sha + STALE mtime (< spawn ts) treated as FAILED",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    gate_verdict_fn = fn _cwd -> "clear" end
    gate_base_sha_fn = fn _cwd -> "aaa" end
    # now_fn (base_opts default) is 1_700_000_000 — a mtime strictly before
    # that is a stale record from an earlier cycle.
    gate_mtime_fn = fn _cwd -> 1_699_999_999 end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     git_head_fn: git_head_fn,
                     gate_verdict_fn: gate_verdict_fn,
                     gate_base_sha_fn: gate_base_sha_fn,
                     gate_mtime_fn: gate_mtime_fn
                   )
                 )
      end)

    assert output =~ "no verified commit under a fresh clear gate"
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    refute File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "6r-fresh-c: exit-0 + clear + sha from a DIFFERENT base treated as FAILED", ctx do
    write_pitch(ctx.ready_dir, "solo")

    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    gate_verdict_fn = fn _cwd -> "clear" end
    # "zzz" does not prefix head_before ("aaa") — a gate record from an
    # unrelated base.
    gate_base_sha_fn = fn _cwd -> "zzz" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     git_head_fn: git_head_fn,
                     gate_verdict_fn: gate_verdict_fn,
                     gate_base_sha_fn: gate_base_sha_fn,
                     gate_mtime_fn: gate_mtime_fn
                   )
                 )
      end)

    assert output =~ "no verified commit under a fresh clear gate"
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    refute File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "6r-fresh-d: nonzero + committed + clear + STALE record does NOT ship (asymmetry closed)",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    # Post-commit-hiccup shape: nonzero exit, but the pitch is
    # already in shipped/ (agent's own commit step ran) — this is exactly the
    # branch a stale record must NOT be allowed to satisfy.
    spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
      File.rename!(
        Path.join(ctx.ready_dir, "#{slug}.md"),
        Path.join(ctx.shipped_dir, "#{slug}.md")
      )

      {:exit_code, 1}
    end

    gate_verdict_fn = fn _cwd -> "clear" end
    gate_base_sha_fn = fn _cwd -> "aaa" end
    # Stale — older than the frozen spawn ts (1_700_000_000).
    gate_mtime_fn = fn _cwd -> 1_699_999_999 end
    transient_fn = fn _jsonl -> false end

    assert {:ok, 0} =
             quiet_drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn,
                 gate_base_sha_fn: gate_base_sha_fn,
                 gate_mtime_fn: gate_mtime_fn,
                 transient_fn: transient_fn
               )
             )

    # The pitch file was physically moved to shipped/ by the stubbed
    # spawn_fn — that side effect is not undone — but the drain must NOT
    # count it as shipped_count (shipped_count stayed 0 above) since the
    # gate record backing the "clear" verdict was stale.
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  # ── 7. Timeout -> stash -> retry once -> ship ───────────────────────────

  test "7: timeout stashes, retries once, then ships", ctx do
    write_pitch(ctx.ready_dir, "solo")

    attempts = start_agent(0)
    stash_calls = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl ->
      n = Agent.get_and_update(attempts, fn n -> {n, n + 1} end)
      if n == 0, do: :timeout, else: {:exit_code, 0}
    end

    git_stash_fn = fn cwd, slug, _reason ->
      Agent.update(stash_calls, &(&1 ++ [{cwd, slug}]))
      :ok
    end

    assert {:ok, 1} =
             quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn))

    assert Agent.get(stash_calls, & &1) == [{ctx.dir, "solo"}]
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  # ── 8. Timeout twice -> skip for run ────────────────────────────────────

  test "8: timeout twice skips slug for the run, left in ready/", ctx do
    write_pitch(ctx.ready_dir, "solo")

    stash_calls = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> :timeout end

    git_stash_fn = fn cwd, slug, _reason ->
      Agent.update(stash_calls, &(&1 ++ [{cwd, slug}]))
      :ok
    end

    assert {:ok, 0} =
             quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn))

    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    assert length(Agent.get(stash_calls, & &1)) == 2
  end

  test "8b: timeout-twice-skip advances to ship other pitches", ctx do
    write_pitch(ctx.ready_dir, "bad")
    write_pitch(ctx.ready_dir, "good")

    spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
      if slug == "bad", do: :timeout, else: {:exit_code, 0}
    end

    assert {:ok, 1} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
    assert File.exists?(Path.join(ctx.ready_dir, "bad.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "good.md"))
  end

  # ── 8c. Blocked-by-unmet-dep -> skip-and-continue ───────────────────────

  test "8c: blocked slug never spawned, stays in ready/, other ships, SKIPPED line emitted",
       ctx do
    write_pitch(ctx.ready_dir, "blocked", "# Pitch: blocked\n\nBlocks-on: draft-dep\n")
    write_pitch(ctx.ready_dir, "good")

    calls = start_agent([])

    spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
      Agent.update(calls, &(&1 ++ [slug]))
      {:exit_code, 0}
    end

    blocked_fn = fn -> %{"blocked" => "draft-dep"} end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} =
                 quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, blocked_fn: blocked_fn))
      end)

    assert File.exists?(Path.join(ctx.ready_dir, "blocked.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "good.md"))
    refute "blocked" in Agent.get(calls, & &1)
    assert output =~ "SKIPPED (unmet dep draft-dep)"
  end

  # ── 9. Dirty-tree stash label + fail-open ───────────────────────────────

  test "9a: git_stash_fn error is fail-open — drain warns and advances", ctx do
    write_pitch(ctx.ready_dir, "solo")

    attempts = start_agent(0)

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl ->
      n = Agent.get_and_update(attempts, fn n -> {n, n + 1} end)
      if n == 0, do: :timeout, else: {:exit_code, 0}
    end

    git_stash_fn = fn _cwd, _slug, _reason -> {:error, :not_a_repo} end

    assert {:ok, 1} =
             quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn))
  end

  test "9b: real-ish git_stash_fn label format queue-timeout:<slug>:<ts>", ctx do
    write_pitch(ctx.ready_dir, "solo")

    labels = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> :timeout end

    git_stash_fn = fn _cwd, slug, reason ->
      Agent.update(labels, &(&1 ++ ["queue-#{reason}:#{slug}:1700000000"]))
      :ok
    end

    assert {:ok, 0} =
             quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn))

    assert Agent.get(labels, & &1) == [
             "queue-timeout:solo:1700000000",
             "queue-timeout:solo:1700000000"
           ]
  end

  # ── 9c. Stash restore before each attempt ───────────────────────────────

  test "9c: timeout stashes, retry restores stashed work first, then ships", ctx do
    write_pitch(ctx.ready_dir, "solo")

    attempts = start_agent(0)
    restore_calls = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl ->
      n = Agent.get_and_update(attempts, fn n -> {n, n + 1} end)
      if n == 0, do: :timeout, else: {:exit_code, 0}
    end

    git_stash_restore_fn = fn cwd, slug ->
      Agent.update(restore_calls, &(&1 ++ [{cwd, slug}]))
      :ok
    end

    assert {:ok, 1} =
             quiet_drain(
               shipped_opts(ctx, spawn_fn: spawn_fn, git_stash_restore_fn: git_stash_restore_fn)
             )

    # Called once per attempt (first attempt + retry) — both with the same slug.
    assert Agent.get(restore_calls, & &1) == [{ctx.dir, "solo"}, {ctx.dir, "solo"}]
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "9d: first attempt with no matching stash is a no-op — drain ships normally", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    git_stash_restore_fn = fn _cwd, _slug -> :ok end

    assert {:ok, 1} =
             quiet_drain(
               shipped_opts(ctx, spawn_fn: spawn_fn, git_stash_restore_fn: git_stash_restore_fn)
             )

    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "9e: stash pop conflict HALTs the drain with the retained ref named", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    git_stash_restore_fn = fn _cwd, slug ->
      {:error,
       "queue: HALTED — stash pop conflict for #{slug}; stash stash@{0} retained, resolve manually then re-run"}
    end

    assert {:error, reason} =
             quiet_drain(
               base_opts(ctx, spawn_fn: spawn_fn, git_stash_restore_fn: git_stash_restore_fn)
             )

    assert reason =~ "stash pop conflict for solo"
    assert reason =~ "stash@{0} retained"
    assert reason =~ "resolve manually"
    # Repo left untouched: pitch stays in ready/, never shipped.
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    refute File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "9f: multiple legacy stashes — restore stub warns residue and advances", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    git_stash_restore_fn = fn _cwd, _slug ->
      IO.puts(
        :stderr,
        "queue: extra queue-timeout:solo: stashes remain: stash@{1} — drop manually"
      )

      :ok
    end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} =
                 quiet_drain(
                   shipped_opts(ctx,
                     spawn_fn: spawn_fn,
                     git_stash_restore_fn: git_stash_restore_fn
                   )
                 )
      end)

    assert output =~ "extra queue-timeout:solo: stashes remain"
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  # ── 9g. Real-git-repo: "fail" reason parks a named branch, not a stash ──

  defp init_git_repo!(dir) do
    File.mkdir_p!(dir)
    System.cmd("git", ["init", "-q"], cd: dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    File.write!(Path.join(dir, "README.md"), "seed\n")
    System.cmd("git", ["add", "."], cd: dir)
    System.cmd("git", ["commit", "-q", "-m", "seed"], cd: dir)
  end

  defp git_branches_matching(dir, glob) do
    {out, 0} = System.cmd("git", ["branch", "--list", glob], cd: dir)

    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim(&1, "* "))
    |> Enum.map(&String.trim/1)
  end

  test "9g: real git repo — \"fail\" reason parks a queue-fail/<slug>/<ts> branch, clean tree",
       ctx do
    init_git_repo!(ctx.dir)
    File.write!(Path.join(ctx.dir, "tracked.txt"), "dirty\n")
    System.cmd("git", ["add", "tracked.txt"], cd: ctx.dir)

    assert {:ok, branch} = LoopQueueDrain.default_git_stash_fn(ctx.dir, "myslug", "fail")
    assert branch =~ ~r{^queue-fail/myslug/\d+$}

    assert git_branches_matching(ctx.dir, "queue-fail/*") == [branch]

    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: ctx.dir)
    assert status == ""

    {stash_list, 0} = System.cmd("git", ["stash", "list"], cd: ctx.dir)
    assert stash_list == ""
  end

  test "9h: real git repo — parked branch diff reproduces the tree, including an untracked file",
       ctx do
    init_git_repo!(ctx.dir)
    File.write!(Path.join(ctx.dir, "tracked.txt"), "dirty\n")
    System.cmd("git", ["add", "tracked.txt"], cd: ctx.dir)
    File.write!(Path.join(ctx.dir, "new_untracked.txt"), "brand new\n")

    assert {:ok, branch} = LoopQueueDrain.default_git_stash_fn(ctx.dir, "myslug", "fail")

    {diff, 0} = System.cmd("git", ["diff", "--name-only", "HEAD", branch], cd: ctx.dir)
    files = diff |> String.split("\n", trim: true) |> Enum.sort()

    assert files == ["new_untracked.txt", "tracked.txt"]
  end

  test "9i: real git repo — \"timeout\" reason creates no queue-fail/ branch, still stashes",
       ctx do
    init_git_repo!(ctx.dir)
    File.write!(Path.join(ctx.dir, "tracked.txt"), "dirty\n")
    System.cmd("git", ["add", "tracked.txt"], cd: ctx.dir)

    assert :ok = LoopQueueDrain.default_git_stash_fn(ctx.dir, "myslug", "timeout")

    assert git_branches_matching(ctx.dir, "queue-fail/*") == []

    {stash_list, 0} = System.cmd("git", ["stash", "list"], cd: ctx.dir)
    assert stash_list =~ "queue-timeout:myslug:"

    assert :ok = LoopQueueDrain.default_git_stash_restore_fn(ctx.dir, "myslug")
    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: ctx.dir)
    assert status =~ "tracked.txt"
  end

  # `git stash branch` DROPS the stash as soon as it succeeds — a failure in
  # a LATER step (`commit`) must not claim "work remains in stash" (it does
  # not: the stash is already gone). Force that failure with a `pre-commit`
  # hook that always rejects, deterministically triggering the post-branch-
  # cut failure path without needing to stub System.cmd.
  defp install_failing_pre_commit_hook!(dir) do
    hooks_dir = Path.join(dir, ".git/hooks")
    File.mkdir_p!(hooks_dir)
    hook_path = Path.join(hooks_dir, "pre-commit")
    File.write!(hook_path, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook_path, 0o755)
  end

  test "9j: real git repo — commit failure AFTER stash branch succeeds reports work is on the branch, not in a stash",
       ctx do
    init_git_repo!(ctx.dir)
    File.write!(Path.join(ctx.dir, "tracked.txt"), "dirty\n")
    System.cmd("git", ["add", "tracked.txt"], cd: ctx.dir)
    install_failing_pre_commit_hook!(ctx.dir)

    # The operator-facing "work is on the branch, not in a stash" warning goes
    # to :stderr by design; park it in the capture buffer rather than the
    # suite's own output (see quiet_drain/1).
    {{:ok, branch}, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        LoopQueueDrain.default_git_stash_fn(ctx.dir, "myslug", "fail")
      end)

    assert branch =~ ~r{^queue-fail/myslug/\d+$}

    # The stash is already gone — `git stash branch` dropped it before the
    # commit step ever ran. Asserting an empty stash list is the core
    # regression guard: a stale "work remains in stash" message would be a
    # lie here, since there is nothing left to pop.
    {stash_list, 0} = System.cmd("git", ["stash", "list"], cd: ctx.dir)
    assert stash_list == ""

    # The branch exists and carries the work as UNCOMMITTED changes (commit
    # was blocked by the hook) — the caller is left checked out on it so the
    # operator's next `git status` sees exactly what needs finishing.
    assert git_branches_matching(ctx.dir, "queue-fail/*") == [branch]

    {current_branch_out, 0} =
      System.cmd("git", ["symbolic-ref", "--short", "-q", "HEAD"], cd: ctx.dir)

    assert String.trim(current_branch_out) == branch

    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: ctx.dir)
    assert status =~ "tracked.txt"
  end

  # ── 10. Lock contention ─────────────────────────────────────────────────

  test "10a: live lock refuses a second queue", ctx do
    File.write!(ctx.lock_path, "99999 queue\n")
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    pid_alive_fn = fn _pid -> true end

    assert {:error, reason} =
             quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, pid_alive_fn: pid_alive_fn))

    assert reason =~ "already running"
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
  end

  test "10b: stale (dead-pid) lock is reclaimed and drain proceeds", ctx do
    File.write!(ctx.lock_path, "99999 queue\n")
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    pid_alive_fn = fn _pid -> false end

    assert {:ok, 1} =
             quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, pid_alive_fn: pid_alive_fn))

    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    refute File.exists?(ctx.lock_path)
  end

  # ── Leg 1: stale legacy manifest cleared at startup ─────────────────────

  test "L1: stale build-queue.json is removed at drain startup", ctx do
    gate_pending = Path.join([ctx.dir, "codegen", "gate-pending"])
    File.mkdir_p!(gate_pending)
    manifest = Path.join(gate_pending, "build-queue.json")
    File.write!(manifest, "{}")
    assert File.exists?(manifest)

    write_pitch(ctx.ready_dir, "solo")
    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    assert {:ok, 1} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
    refute File.exists?(manifest)
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  # ── Leg 2: default lock path unified with legacy (gate-pending) ──────────

  test "L2: default lock path is codegen/gate-pending/queue.lock", ctx do
    gate_pending = Path.join([ctx.dir, "codegen", "gate-pending"])
    File.mkdir_p!(gate_pending)
    default_lock = Path.join(gate_pending, "queue.lock")
    File.write!(default_lock, "99999 queue\n")

    write_pitch(ctx.ready_dir, "solo")
    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    pid_alive_fn = fn _pid -> true end

    opts =
      ctx
      |> base_opts(spawn_fn: spawn_fn, pid_alive_fn: pid_alive_fn)
      |> Keyword.delete(:lock_path)

    assert {:error, reason} = quiet_drain(opts)
    assert reason =~ "already running"
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
  end

  # ── 11. Resume by re-scan (refillable mid-run) ──────────────────────────

  test "11: re-scan picks up a pitch written as a side-effect mid-run", ctx do
    write_pitch(ctx.ready_dir, "a")

    spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
      if slug == "a" do
        write_pitch(ctx.ready_dir, "c")
      end

      {:exit_code, 0}
    end

    assert {:ok, 2} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
    assert File.exists?(Path.join(ctx.shipped_dir, "a.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "c.md"))
  end

  # ── 11b. [n/N] counts CONCLUDED pitches, not ships ──────────────────────
  # A queue whose pitches fail must still ADVANCE the printed index — before
  # the concluded_count fix, idx was `shipped_count + 1`, so a queue with no
  # ships repeated "[1/N]" forever regardless of how many pitches concluded.

  test "11b: [n/N] advances past a deterministically-failed pitch", ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b")
    write_pitch(ctx.ready_dir, "c")

    spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
      if slug == "a", do: {:exit_code, 1}, else: {:exit_code, 0}
    end

    transient_fn = fn _jsonl -> false end

    # "a" (nonzero) must NOT look committed — head_before == head_after
    # ("zzz", unmoved), calls 0-1, so handle_nonzero_exit/8 falls straight to
    # the deterministic-failure branch. "b" and "c" (exit 0) each need a real
    # forward HEAD move (head_before -> head_after) under a fresh clear gate
    # to ship — calls 2-3 = b's (before "aaa", after "bbb"), calls 4-5 =
    # c's (before "bbb", after "ccc").
    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)

      case n do
        0 -> "zzz"
        1 -> "zzz"
        2 -> "aaa"
        3 -> "bbb"
        4 -> "bbb"
        _ -> "ccc"
      end
    end

    gate_verdict_calls = start_agent(0)
    gate_sha_calls = start_agent(0)

    # gate_verdict_fn is called once per handler invocation: call 0 = "a"
    # (nonzero, committed? already false — value here is immaterial), call
    # 1 = "b" (exit 0, must be clear), call 2 = "c" (exit 0, must be clear).
    gate_verdict_fn = fn _cwd ->
      n = Agent.get_and_update(gate_verdict_calls, fn n -> {n, n + 1} end)
      if n == 0, do: "failed", else: "clear"
    end

    # Gate ran before each commit — base_sha matches that attempt's
    # head_before ("aaa" for b, "bbb" for c), never its head_after.
    # gate_base_sha_fn is short-circuited out entirely for "a" (its
    # gate_verdict_fn call reads "failed", so the `and gate_fresh?/3` leg
    # never evaluates) — this fn is only ever called for "b" (n=0, its
    # first call) and "c" (n=1, its second call).
    gate_base_sha_fn = fn _cwd ->
      n = Agent.get_and_update(gate_sha_calls, fn n -> {n, n + 1} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    gate_mtime_fn = fn _cwd -> 1_700_000_000 end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 2} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     transient_fn: transient_fn,
                     git_head_fn: git_head_fn,
                     gate_verdict_fn: gate_verdict_fn,
                     gate_base_sha_fn: gate_base_sha_fn,
                     gate_mtime_fn: gate_mtime_fn
                   )
                 )
      end)

    # "a" fails (terminal, non-transient) at index 1; "b" and "c" ship at
    # indexes 2 and 3 — the index must NOT stall at "[1/3]" for all three.
    assert output =~ "[1/3] a ... FAILED"
    assert output =~ "[2/3] b ... shipped"
    assert output =~ "[3/3] c ... shipped"
  end

  test "11c: [n/N] holds (does not advance) across a transient retry of the same slug", ctx do
    write_pitch(ctx.ready_dir, "solo")

    attempts = start_agent(0)

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      n = Agent.get_and_update(attempts, fn n -> {n, n + 1} end)

      if n == 0 do
        File.write!(jsonl, "no result record here")
        {:exit_code, 1}
      else
        {:exit_code, 0}
      end
    end

    # Same head/gate fixture shape as test 4 — attempt 1 (nonzero) must not
    # look committed/clear, attempt 2 (exit 0) must.
    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 3, do: "bbb", else: "aaa"
    end

    gate_calls = start_agent(0)

    gate_verdict_fn = fn _cwd ->
      n = Agent.get_and_update(gate_calls, fn n -> {n, n + 1} end)
      if n == 1, do: "clear", else: "failed"
    end

    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end
    transient_fn = fn _jsonl -> true end
    sleep_fn = fn _secs -> :ok end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     git_head_fn: git_head_fn,
                     gate_verdict_fn: gate_verdict_fn,
                     gate_base_sha_fn: gate_base_sha_fn,
                     gate_mtime_fn: gate_mtime_fn,
                     transient_fn: transient_fn,
                     sleep_fn: sleep_fn
                   )
                 )
      end)

    # A retry of the SAME pitch never advances the index — both the
    # "provider outage detected" line and the later "shipped" line read "[1/1]".
    assert output =~ "[1/1] solo ... provider outage detected"
    assert output =~ "[1/1] solo ... shipped"
    refute output =~ "[2/1]"
  end

  # ── 12. Budget default resolution ───────────────────────────────────────
  # NOTE: pitch_budget_from_env/0, max_retries_from_env/0, retry_delays_from_env/0,
  # and max_consecutive_fails_from_env/0 tests that mutate CODEGEN_BUILD_QUEUE_*
  # env vars live in the async: false sibling module at the bottom of this
  # file (LoopQueueDrainEnvSerialTest) — System.put_env/2 is process-global
  # and races with any other async: true test reading the same env var
  # mid-flight (e.g. the grandchild-reap test below, which also reads this
  # var).

  # ── Harness -> mention-prefix mapping ───────────────────────────────────

  describe "mention_prefix/1" do
    test "claude -> @" do
      assert LoopQueueDrain.mention_prefix("claude") == "@"
    end

    test "unknown harness raises" do
      assert_raise RuntimeError, ~r/unknown harness/, fn ->
        LoopQueueDrain.mention_prefix("bogus")
      end
    end
  end

  describe "pitch_arg_for/3" do
    test "claude -> @-prefixed absolute path" do
      assert LoopQueueDrain.pitch_arg_for("x", "claude", "/repo") ==
               "@/repo/codegen/pitches/ready/x.md"
    end
  end

  # ── Env-mutating tests above use System.put_env/delete_env (process-global) —
  # keep this module async: true (no shared queue.lock/ready state), but note
  # a sibling async: false module would be required if these env mutations
  # ever raced with a concurrently-running test reading the same keys. None
  # of the drain/1 filesystem tests read these env vars (opts override them),
  # so no race exists today.

  describe "default_spawn_fn/5 timeout + normal exit" do
    defp write_script(dir, name, body) do
      path = Path.join(dir, name)
      File.write!(path, body)
      File.chmod!(path, 0o755)
      path
    end

    # NOTE: "timeout kills the child process tree via the kill_fn seam" (which
    # sets CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS) lives in the async: false
    # sibling module at the bottom of this file (LoopQueueDrainEnvSerialTest)
    # — System.put_env/2 is process-global and races with other async: true
    # tests reading the same env var mid-flight.

    test "normal exit writes merged stdout+stderr and returns exit code", ctx do
      jsonl = Path.join(ctx.dir, "out.jsonl")

      script =
        write_script(ctx.dir, "echoer.sh", """
        #!/usr/bin/env bash
        printf 'OUT'
        printf 'ERR' >&2
        exit 0
        """)

      Process.put(:__queue_drain_build_bin__, script)
      on_exit(fn -> Process.delete(:__queue_drain_build_bin__) end)

      output =
        capture_io(:stderr, fn ->
          send(
            self(),
            {:result,
             LoopQueueDrain.default_spawn_fn("slug", "claude", "phoenix", ctx.dir, jsonl)}
          )
        end)

      result =
        receive do
          {:result, r} -> r
        end

      assert result == {:exit_code, 0}
      assert output =~ "OUT"
      assert output =~ "ERR"
      contents = File.read!(jsonl)
      assert contents =~ "OUT"
      assert contents =~ "ERR"
    end

    test "passes --harness/--stack/--cwd to the per-pitch child (no engine flag)", ctx do
      jsonl = Path.join(ctx.dir, "out.jsonl")
      spawn_args_file = Path.join(ctx.dir, "spawn_args.txt")

      script =
        write_script(ctx.dir, "argcapture.sh", """
        #!/usr/bin/env bash
        printf '%s\\n' "$@" > "#{spawn_args_file}"
        exit 0
        """)

      Process.put(:__queue_drain_build_bin__, script)
      on_exit(fn -> Process.delete(:__queue_drain_build_bin__) end)

      capture_io(:stderr, fn ->
        send(
          self(),
          {:result, LoopQueueDrain.default_spawn_fn("slug", "claude", "phoenix", ctx.dir, jsonl)}
        )
      end)

      receive do
        {:result, {:exit_code, 0}} -> :ok
      end

      spawned_args = File.read!(spawn_args_file)
      assert spawned_args =~ "--harness=claude"
      assert spawned_args =~ "--stack=phoenix"
      refute spawned_args =~ "--elixir"
      refute spawned_args =~ "--non-interactive"
    end

    test "sets CODEGEN_BUILD_LOCK_HELD=1 in the per-pitch child env (queue bypass)", ctx do
      jsonl = Path.join(ctx.dir, "out.jsonl")
      env_capture_file = Path.join(ctx.dir, "env_capture.txt")

      script =
        write_script(ctx.dir, "envcapture.sh", """
        #!/usr/bin/env bash
        printf '%s' "$CODEGEN_BUILD_LOCK_HELD" > "#{env_capture_file}"
        exit 0
        """)

      Process.put(:__queue_drain_build_bin__, script)
      on_exit(fn -> Process.delete(:__queue_drain_build_bin__) end)

      capture_io(:stderr, fn ->
        send(
          self(),
          {:result, LoopQueueDrain.default_spawn_fn("slug", "claude", "phoenix", ctx.dir, jsonl)}
        )
      end)

      receive do
        {:result, {:exit_code, 0}} -> :ok
      end

      assert File.read!(env_capture_file) == "1"
    end

    test "Move 3: updates the lock file's tree= token when __queue_drain_lock_path__ is set",
         ctx do
      jsonl = Path.join(ctx.dir, "out.jsonl")
      lock_path = Path.join(ctx.dir, "queue.lock")
      File.write!(lock_path, "#{System.pid()} queue\n")

      script =
        write_script(ctx.dir, "quick.sh", """
        #!/usr/bin/env bash
        exit 0
        """)

      Process.put(:__queue_drain_build_bin__, script)
      Process.put(:__queue_drain_lock_path__, lock_path)

      on_exit(fn ->
        Process.delete(:__queue_drain_build_bin__)
        Process.delete(:__queue_drain_lock_path__)
      end)

      capture_io(:stderr, fn ->
        send(
          self(),
          {:result, LoopQueueDrain.default_spawn_fn("slug", "claude", "phoenix", ctx.dir, jsonl)}
        )
      end)

      receive do
        {:result, {:exit_code, 0}} -> :ok
      end

      assert File.read!(lock_path) =~ ~r/^#{System.pid()} queue tree=\d+\n$/
    end

    test "Move 3: is a no-op (no crash) when __queue_drain_lock_path__ is unset", ctx do
      jsonl = Path.join(ctx.dir, "out.jsonl")

      script =
        write_script(ctx.dir, "quick2.sh", """
        #!/usr/bin/env bash
        exit 0
        """)

      Process.put(:__queue_drain_build_bin__, script)
      on_exit(fn -> Process.delete(:__queue_drain_build_bin__) end)

      capture_io(:stderr, fn ->
        send(
          self(),
          {:result, LoopQueueDrain.default_spawn_fn("slug", "claude", "phoenix", ctx.dir, jsonl)}
        )
      end)

      assert_receive {:result, {:exit_code, 0}}
    end
  end

  # ── default_kill_tree/1 — ppid descendant-walk reap ─────────────────────

  describe "default_kill_tree/1 (via __queue_drain_ps_fn__ seam)" do
    # NOTE: "reaps a spawned child's own subprocess grandchild via the ppid
    # walk" (which sets CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS) lives in the
    # async: false sibling module at the bottom of this file
    # (LoopQueueDrainEnvSerialTest) — System.put_env/2 is process-global and
    # races with other async: true tests reading the same env var mid-flight.

    test "default_ps_lister/0 parses `ps -A -o pid=,ppid=` into {pid, ppid} tuples" do
      table = LoopQueueDrain.default_ps_lister()
      assert is_list(table)
      assert length(table) > 0
      assert Enum.all?(table, fn {pid, ppid} -> is_integer(pid) and is_integer(ppid) end)
      # init/launchd (pid 1) must be present on any POSIX host
      assert Enum.any?(table, fn {pid, _ppid} -> pid == 1 end)
    end
  end

  # ── Move 1: exit-path reap ───────────────────────────────────────────────

  describe "reap_in_flight_tree/0" do
    test "is a no-op when nothing is recorded as in-flight" do
      assert LoopQueueDrain.reap_in_flight_tree() == :ok
    end
  end

  # ── Move 4: startup preflight (orphan codegen-build scan) ───────────────

  describe "drain/1 Move 4 preflight — refuse_if_build_orphan" do
    test "refuses BEFORE acquiring the lock when orphan_scan_fn finds a live codegen-build pid",
         ctx do
      write_pitch(ctx.ready_dir, "solo")

      opts =
        base_opts(ctx, spawn_fn: fn _s, _h, _st, _c, _j -> {:exit_code, 0} end)
        |> Keyword.put(:orphan_scan_fn, fn _cwd -> ["424242"] end)

      assert {:error, reason} = quiet_drain(opts)
      assert reason =~ "orphan codegen-build process(es)"
      assert reason =~ "424242"
      assert reason =~ "kill -9 424242"

      # The lock must NEVER have been written — the preflight refuses before
      # BuildLock.acquire runs.
      refute File.exists?(ctx.lock_path)
    end

    test "proceeds normally when orphan_scan_fn returns []", ctx do
      write_pitch(ctx.ready_dir, "solo")

      opts =
        shipped_opts(ctx, spawn_fn: fn _s, _h, _st, _c, _j -> {:exit_code, 0} end)
        |> Keyword.put(:orphan_scan_fn, fn _cwd -> [] end)

      assert {:ok, 1} = quiet_drain(opts)
    end

    test "default_build_orphan_scan/1 excludes this process's own OS pid" do
      # Sanity: the real scan never matches a nonexistent pattern in this
      # test's own cwd (no codegen-build process is bound to a random tmp
      # dir path), so it degrades to [] rather than falsely refusing.
      random_cwd = "/tmp/never-a-real-cwd-#{:erlang.unique_integer([:positive])}"
      assert LoopQueueDrain.default_build_orphan_scan(random_cwd) == []
    end
  end

  # ── Startup recovery — InterruptedCycleRecovery wiring ───────────────────
  # `drain/1`'s `with` chain runs recovery AFTER refuse_if_build_orphan +
  # BuildLock.acquire and BEFORE publish_preflight_fn (see the drain/1
  # moduledoc `with` clause order). No :reconcile_fn seam exists — these
  # tests drive real on-disk building/ + journal state so
  # InterruptedCycleRecovery.reconcile/1 (called for real, no stub) resolves
  # to the same shapes route_reconcile_result/3 (codegen.loop.ex) branches
  # on.

  describe "drain/1 startup recovery — InterruptedCycleRecovery wiring" do
    test "quarantines an incompatible recovery once, skips it on restart, and ships unrelated ready work",
         ctx do
      {_, 0} = System.cmd("git", ["init", "-q", ctx.dir])
      System.cmd("git", ["-C", ctx.dir, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", ctx.dir, "config", "user.name", "Test"])
      File.write!(Path.join(ctx.dir, ".gitignore"), "codegen/\n")
      File.write!(Path.join(ctx.dir, "tracked.txt"), "base\n")
      System.cmd("git", ["-C", ctx.dir, "add", "-A"])
      System.cmd("git", ["-C", ctx.dir, "commit", "-qm", "base"])

      bad_pitch = Path.join(ctx.ready_dir, "bad.md")
      File.write!(bad_pitch, "---\nscope: [tracked.txt]\n---\n# Pitch: bad\n")
      write_pitch(ctx.ready_dir, "good")
      File.write!(Path.join(ctx.dir, "tracked.txt"), "recovered bytes\n")

      assert {:ok, parked} =
               CodegenTestHarness.InterruptedCycleRecovery.park_failure(
                 cwd: ctx.dir,
                 pitch_path: bad_pitch,
                 slug: "bad",
                 namespace: "queue-fail",
                 cause: "test"
               )

      File.write!(Path.join(ctx.dir, "tracked.txt"), "conflicting landed bytes\n")
      System.cmd("git", ["-C", ctx.dir, "add", "tracked.txt"])
      System.cmd("git", ["-C", ctx.dir, "commit", "-qm", "conflict"])
      {head, 0} = System.cmd("git", ["-C", ctx.dir, "rev-parse", "HEAD"])
      head = String.trim(head)

      spawned = start_agent([])

      opts =
        shipped_opts(ctx,
          # No :ordered_fn override — the default LoopQueue.ordered_slugs/1
          # re-reads ready_dir on every scan. "bad" < "good" alphabetically
          # with no dependency edge between them, so it already yields the
          # same ["bad", "good"] order this test wants — but, unlike a
          # static stub, it stops offering "good" once it physically leaves
          # ready_dir on ship. A static `fn _ -> ["bad", "good"] end` here
          # previously caused a livelock: run_loop re-invokes ordered_fn on
          # every scan, and a static stub keeps re-selecting "good" forever
          # after it ships (nothing else tracks "already shipped this run"
          # — that's ordered_fn's job in production). Confirmed root cause
          # of the deterministic gate timeout at this line recorded in
          # codegen/pitches/draft/harness-builds-finish-or-preserve-the-truth.md
          # incident #3.
          spawn_fn: fn slug, _h, _s, _cwd, _jsonl ->
            Agent.update(spawned, &(&1 ++ [slug]))
            {:exit_code, 0}
          end,
          git_ancestor_fn: fn _cwd, _ancestor, _descendant -> true end
        )

      assert {:ok, 1} = quiet_drain(opts)
      assert Agent.get(spawned, & &1) == ["good"]
      assert File.exists?(bad_pitch)

      assert {:ok, quarantined} =
               CodegenTestHarness.InterruptedCycleRecovery.active_dossier(ctx.dir, "bad")

      assert quarantined["stage"] == "reconciliation_required"
      assert quarantined["reconciliation_head"] == head
      assert quarantined["recovery_ref"] == parked["recovery_ref"]
      assert {"", 0} = System.cmd("git", ["-C", ctx.dir, "status", "--porcelain"])

      # A fresh drain sees the durable state and makes zero child attempts
      # for bad; the pitch/ref/worktree remain available for reconciliation.
      assert {:ok, 0} = quiet_drain(opts)
      assert Agent.get(spawned, & &1) == ["good"]

      assert {:ok, ^quarantined} =
               CodegenTestHarness.InterruptedCycleRecovery.active_dossier(ctx.dir, "bad")

      assert File.exists?(bad_pitch)
      assert {"", 0} = System.cmd("git", ["-C", ctx.dir, "status", "--porcelain"])
    end

    test "reconcile error short-circuits BEFORE publish_preflight_fn ever runs", ctx do
      building_dir = Path.join([ctx.dir, "codegen", "pitches", "building"])
      File.mkdir_p!(building_dir)
      # Two building/ claims at once is the multiple-claims refusal shape —
      # InterruptedCycleRecovery.reconcile/1 returns {:error, _} without
      # ever reaching publish_preflight_fn.
      File.write!(Path.join(building_dir, "one.md"), "# Pitch: one\n")
      File.write!(Path.join(building_dir, "two.md"), "# Pitch: two\n")

      {:ok, preflight_called} = Agent.start_link(fn -> false end)

      opts =
        base_opts(ctx,
          publish_preflight_fn: fn _cwd ->
            Agent.update(preflight_called, fn _ -> true end)
            :ok
          end
        )

      assert {:error, reason} = quiet_drain(opts)
      assert reason =~ "multiple building pitches"
      refute Agent.get(preflight_called, & &1)
    end

    test "a resumable checkpoint is reconciled but earns NO priority — ordinary order wins",
         ctx do
      write_pitch(ctx.ready_dir, "a")
      write_pitch(ctx.ready_dir, "resumed")
      write_pitch(ctx.ready_dir, "b")

      building_dir = Path.join([ctx.dir, "codegen", "pitches", "building"])
      journal_path = Path.join([ctx.dir, "codegen", "gate-pending", "interrupted-recovery.json"])
      File.mkdir_p!(building_dir)
      File.mkdir_p!(Path.dirname(journal_path))

      File.write!(Path.join(building_dir, "resumed.md"), "# Pitch: resumed\n")

      # resume_head_unmoved?/2 shells real `git rev-parse HEAD` against ctx.dir
      # (no seam exists for it) — ctx.dir must be a real repo with a real HEAD
      # so gate_result_base_sha_fn's stub can genuinely prefix-match it.
      {_, 0} = System.cmd("git", ["init", "-q", ctx.dir])
      System.cmd("git", ["-C", ctx.dir, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", ctx.dir, "config", "user.name", "Test"])
      System.cmd("git", ["-C", ctx.dir, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(ctx.dir, "seed.txt"), "seed\n")
      System.cmd("git", ["-C", ctx.dir, "add", "."])
      System.cmd("git", ["-C", ctx.dir, "commit", "-q", "-m", "seed"])
      {head, 0} = System.cmd("git", ["-C", ctx.dir, "rev-parse", "HEAD"])
      head = String.trim(head)

      File.write!(
        journal_path,
        Jason.encode!(%{
          "branch" => "",
          "original_ref" => "main",
          "slug" => "resumed",
          "stage" => "resume_pending",
          "transaction_id" => "interrupted-recovery-drain-test",
          "updated_at" => "2026-07-22T00:00:00Z"
        })
      )

      spawned = start_agent([])

      opts =
        shipped_opts(ctx,
          spawn_fn: fn slug, _h, _st, cwd_arg, jsonl_arg ->
            Agent.update(spawned, fn s -> s ++ [{slug, cwd_arg, jsonl_arg}] end)
            {:exit_code, 0}
          end,
          # Real ready/ order, unmodified — this is exactly the point: a
          # reconciled/resumable checkpoint must NOT reorder it (see pitch
          # "restarted builds resume owned work" — `state.recovery` and
          # `prioritize_recovered_slug/2` are both removed; a dormant
          # recovery earns no priority over ordinary arrival order).
          ordered_fn: fn ready_dir -> CodegenTestHarness.LoopQueue.ordered_slugs(ready_dir) end,
          # shipped_opts' git_head_fn returns synthetic ever-incrementing
          # "head-N" strings — never real revs. The real default_git_ancestor_fn
          # would shell `git merge-base --is-ancestor` against those and hang.
          # Treat every "shipped" child as a non-orphaning fast-forward.
          git_ancestor_fn: fn _cwd, _ancestor, _descendant -> true end
        )
        |> Keyword.merge(
          cycle_state_get_fn: fn _ -> "GATED" end,
          cycle_state_slug_fn: fn _ -> "resumed" end,
          read_verdict_fn: fn _ -> :clear end,
          gate_result_base_sha_fn: fn _ -> head end,
          gate_tree_match_fn: fn _ -> true end
        )

      # `resumed.md` was moved back to ready/ by reconcile before the drain
      # ever calls ordered_fn. Spawn order must equal PLAIN alphabetical
      # ready/ order — "resumed" earns no priority from having been
      # reconciled.
      assert {:ok, _shipped} = quiet_drain(opts)
      refute File.exists?(Path.join(building_dir, "resumed.md"))

      spawn_order = Agent.get(spawned, & &1) |> Enum.map(fn {slug, _, _} -> slug end)
      assert spawn_order == ["a", "b", "resumed"]
    end

    test "when the resumed slug is absent from the ready list, order is unchanged", ctx do
      write_pitch(ctx.ready_dir, "a")
      write_pitch(ctx.ready_dir, "b")

      # No building/ claim and no journal at all -> reconcile resolves
      # {:ok, :none}; ordinary ordering runs untouched.
      opts = shipped_opts(ctx, spawn_fn: fn _s, _h, _st, _c, _j -> {:exit_code, 0} end)

      assert {:ok, 2} = quiet_drain(opts)
    end

    test "forwards clean-checkpoint seam and dispatches the requeued full run", ctx do
      building_dir = Path.join([ctx.dir, "codegen", "pitches", "building"])
      journal_path = Path.join([ctx.dir, "codegen", "gate-pending", "interrupted-recovery.json"])
      File.mkdir_p!(Path.dirname(journal_path))
      write_pitch(ctx.ready_dir, "resumed")

      {_, 0} = System.cmd("git", ["init", "-q", ctx.dir])
      System.cmd("git", ["-C", ctx.dir, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", ctx.dir, "config", "user.name", "Test"])
      File.write!(Path.join(ctx.dir, ".gitignore"), "codegen/\n")
      File.write!(Path.join(ctx.dir, "seed.txt"), "seed\n")
      System.cmd("git", ["-C", ctx.dir, "add", "."])
      System.cmd("git", ["-C", ctx.dir, "commit", "-q", "-m", "seed"])
      {head, 0} = System.cmd("git", ["-C", ctx.dir, "rev-parse", "HEAD"])
      head = String.trim(head)

      File.write!(
        journal_path,
        Jason.encode!(%{
          "branch" => "",
          "original_ref" => "master",
          "slug" => "resumed",
          "stage" => "resume_pending",
          "transaction_id" => "interrupted-recovery-clean-drain-test",
          "updated_at" => "2026-07-22T00:00:00Z"
        })
      )

      {:ok, seam_calls} = Agent.start_link(fn -> 0 end)
      {:ok, spawned} = Agent.start_link(fn -> [] end)

      opts =
        shipped_opts(ctx,
          spawn_fn: fn slug, _h, _st, _cwd, _jsonl ->
            Agent.update(spawned, &(&1 ++ [slug]))
            {:exit_code, 0}
          end
        )
        |> Keyword.merge(
          cycle_state_get_fn: fn _ -> "GATED" end,
          cycle_state_slug_fn: fn _ -> "resumed" end,
          read_verdict_fn: fn _ -> :clear end,
          gate_result_base_sha_fn: fn _ -> head end,
          gate_tree_match_fn: fn _ -> true end,
          resume_work_present_fn: fn _ ->
            Agent.update(seam_calls, &(&1 + 1))
            false
          end
        )

      assert {:ok, 1} = quiet_drain(opts)
      assert Agent.get(seam_calls, & &1) == 1
      assert Agent.get(spawned, & &1) == ["resumed"]
      refute File.exists?(journal_path)
      refute File.exists?(Path.join(building_dir, "resumed.md"))
    end
  end

  # ── Queue terminal failures share strict parking (dossier recording) ──────
  # See pitch "restarted builds resume owned work": a queue terminal failure
  # (the `true ->` catch-all arm) records a recovery dossier via
  # `InterruptedCycleRecovery.park_failure/1` — namespace "queue-fail" — the
  # SAME dossier authority a direct terminal failure uses, so a later
  # same-slug selection can materialize the queue's own parked bytes.
  # Recording is best-effort and NEVER changes the existing `git_stash_fn`
  # branch-parking contract these tests otherwise stub away.

  describe "park_failed_tree/2 — queue terminal failures record a recovery dossier" do
    test "the general catch-all arm records a queue-fail dossier for the failed slug", ctx do
      System.cmd("git", ["init", "-q"], cd: ctx.dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: ctx.dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: ctx.dir)
      File.write!(Path.join(ctx.dir, ".gitignore"), "codegen/\n")
      File.write!(Path.join(ctx.dir, "tracked.txt"), "base\n")
      System.cmd("git", ["add", "-A"], cd: ctx.dir)
      System.cmd("git", ["commit", "-qm", "base"], cd: ctx.dir)

      write_pitch(ctx.ready_dir, "solo", "---\nscope: [tracked.txt]\n---\n# Pitch: solo\n")

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl ->
        File.write!(Path.join(ctx.dir, "tracked.txt"), "dirty from a deterministic failure\n")
        {:exit_code, 1}
      end

      transient_fn = fn _jsonl -> false end

      # Real git_stash_fn (not the hermetic no-op stub) — the dossier must
      # be recorded BEFORE the stash push cleans the tree.
      git_stash_fn = &LoopQueueDrain.default_git_stash_fn/3

      capture_io(:stderr, fn ->
        quiet_drain(
          base_opts(ctx,
            spawn_fn: spawn_fn,
            transient_fn: transient_fn,
            git_stash_fn: git_stash_fn
          )
        )
      end)

      assert {:ok, dossier} =
               CodegenTestHarness.InterruptedCycleRecovery.active_dossier(ctx.dir, "solo")

      assert dossier["namespace"] == "queue-fail"
      assert dossier["stage"] == "ready"
      assert {"", 0} = System.cmd("git", ["status", "--porcelain"], cd: ctx.dir)
    end
  end

  # ── Boot-time :jason force-load (ensure_decode_deps) ─────────────────────
  # Guards against a lazily-loaded :jason getting unloaded from under the
  # parent drain by a child's concurrent `_build` recompile — see the
  # `:load_deps_fn` moduledoc entry.

  describe "drain/1 boot preflight — ensure_decode_deps" do
    test "happy path: default load_deps_fn does not perturb a normal drain", ctx do
      write_pitch(ctx.ready_dir, "solo")

      opts = shipped_opts(ctx, spawn_fn: fn _s, _h, _st, _c, _j -> {:exit_code, 0} end)

      assert {:ok, 1} = quiet_drain(opts)
    end

    test "refuses BEFORE any spawn when load_deps_fn cannot load :jason", ctx do
      write_pitch(ctx.ready_dir, "solo")

      test_pid = self()

      spawn_fn = fn _s, _h, _st, _c, _j ->
        send(test_pid, :spawned)
        {:exit_code, 0}
      end

      opts =
        base_opts(ctx, spawn_fn: spawn_fn)
        |> Keyword.put(:load_deps_fn, fn Jason -> {:error, :nofile} end)

      assert {:error, reason} = quiet_drain(opts)
      assert reason =~ "jason"
      assert reason =~ "mix deps.get"

      # The refusal must land before any child is spawned — no money spent.
      refute_received :spawned

      # The lock must NEVER have been written — the boot check refuses
      # before BuildLock.acquire (and before the orphan scan) run.
      refute File.exists?(ctx.lock_path)
    end
  end

  # ── Queue-wide spend cap (`CODEGEN_BUILD_QUEUE_BUDGET_USD` / `--max-budget-usd`
  # sibling at the drain layer) ───────────────────────────────────────────────
  # Every child's LAST `{"type":"result",...}` JSONL record carries
  # `total_cost_usd` (produced by `Mix.Tasks.Codegen.Loop.emit_loop_telemetry/1`).
  # These tests write that record directly via `spawn_fn`, mirroring the
  # existing "1h" jsonl-write pattern above, and drive the accounting through
  # the real `drain/1` entry point (never calling the private accumulator
  # helpers directly).

  test "(d) accumulation counts every concluded child incl. a retried slug, and the total is always reported",
       ctx do
    write_pitch(ctx.ready_dir, "solo")

    attempts = start_agent(0)

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      n = Agent.get_and_update(attempts, fn n -> {n, n + 1} end)

      if n == 0 do
        File.write!(jsonl, ~s({"type":"result","total_cost_usd":1.5}\n))
        {:exit_code, 1}
      else
        File.write!(jsonl, ~s({"type":"result","total_cost_usd":2.25}\n))
        {:exit_code, 0}
      end
    end

    # Same fixture shape as test "4: transient failure retries once with
    # backoff then ships" above — attempt 1 (nonzero) must NOT look
    # committed/clear, else handle_nonzero_exit/7's committer-post-commit-
    # hiccup branch ships early on the wrong attempt and the retry never
    # actually re-spawns (silently masking this very accumulation bug).
    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 3, do: "bbb", else: "aaa"
    end

    gate_calls = start_agent(0)

    gate_verdict_fn = fn _cwd ->
      n = Agent.get_and_update(gate_calls, fn n -> {n, n + 1} end)
      if n == 1, do: "clear", else: "failed"
    end

    gate_base_sha_fn = fn _cwd -> "aaa" end
    gate_mtime_fn = fn _cwd -> 1_700_000_000 end
    transient_fn = fn _jsonl -> true end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} =
                 quiet_drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     git_head_fn: git_head_fn,
                     gate_verdict_fn: gate_verdict_fn,
                     gate_base_sha_fn: gate_base_sha_fn,
                     gate_mtime_fn: gate_mtime_fn,
                     transient_fn: transient_fn
                   )
                 )
      end)

    assert Agent.get(attempts, & &1) == 2

    # Both attempts (the retried failure AND the eventual ship) are counted:
    # 1.5 + 2.25 = 3.75 — never just the last attempt's cost.
    assert output =~ "queue: 1 shipped, 0 failed, 0 drafted, $3.75 total"
  end

  test "(d2) no-cap control: report still prints total with no ceiling set", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      File.write!(jsonl, ~s({"type":"result","total_cost_usd":0.42}\n))
      {:exit_code, 0}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      end)

    assert output =~ "queue: 1 shipped, 0 failed, 0 drafted, $0.42 total"
  end

  test "(e) ceiling halts BEFORE the next spawn — remaining pitches stay in ready/", ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b", "# Pitch: b\n\nBlocks-on: a\n")
    write_pitch(ctx.ready_dir, "c", "# Pitch: c\n\nBlocks-on: b\n")

    calls = start_agent([])

    spawn_fn = fn slug, _h, _s, _cwd, jsonl ->
      Agent.update(calls, &(&1 ++ [slug]))
      # Each pitch costs $6 — the second spawn crosses a $10 ceiling, so the
      # THIRD spawn must never happen.
      File.write!(jsonl, ~s({"type":"result","total_cost_usd":6.0}\n))
      {:exit_code, 0}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:error, reason} =
                 quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, queue_budget_usd: 10.0))

        assert reason =~ "spend ceiling reached"
        assert reason =~ "$12.00"
        assert reason =~ "$10.00"
        assert reason =~ "c"
      end)

    # Exactly two spawns — the third pitch never launches.
    assert Agent.get(calls, & &1) == ["a", "b"]
    assert output =~ "queue: 2 shipped, 0 failed, 0 drafted, $12.00 total"

    # a and b shipped (their own outcome already landed); c is untouched.
    assert File.exists?(Path.join(ctx.shipped_dir, "a.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "b.md"))
    assert File.exists?(Path.join(ctx.ready_dir, "c.md"))
  end

  test "(f) fail-closed: unaccountable child spend halts the drain under an active ceiling",
       ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b", "# Pitch: b\n\nBlocks-on: a\n")

    calls = start_agent([])

    spawn_fn = fn slug, _h, _s, _cwd, jsonl ->
      Agent.update(calls, &(&1 ++ [slug]))
      # No result record written at all — mirrors a killed/timed-out child
      # that never got to emit its final envelope.
      File.write!(jsonl, "no result record here")
      {:exit_code, 0}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:error, reason} =
                 quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn, queue_budget_usd: 10.0))

        assert reason =~ "cannot account for"
        assert reason =~ "no result record"
      end)

    # Only the first pitch ever spawns — the drain halts before "b".
    assert Agent.get(calls, & &1) == ["a"]

    assert output =~
             "queue: 1 shipped, 0 failed, 0 drafted, unknown (unaccountable child spend) total"
  end

  test "(f2) sibling control: same unaccountable jsonl, NO ceiling -> drain completes normally",
       ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b", "# Pitch: b\n\nBlocks-on: a\n")

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      File.write!(jsonl, "no result record here")
      {:exit_code, 0}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 2} = quiet_drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      end)

    assert output =~
             "queue: 2 shipped, 0 failed, 0 drafted, unknown (unaccountable child spend) total"
  end

  # ── --watch: terminal-condition continuation, quiescence gate, keychain ──
  #
  # `:watch` never returns on its own on an empty scan (that IS the pitch —
  # the drain keeps polling forever). Every test below runs the drain to
  # some assertable side effect, then deliberately breaks out of the
  # otherwise-infinite watch loop by having `sleep_fn` raise a sentinel
  # error once its assertions are already satisfied — caught via
  # `assert_raise`. This is the SAME idiom the file already uses to bound
  # cyclic/unreachable-else raises (see test 4 "cyclic dependency").

  defmodule WatchStop do
    defexception message: "watch_stop_sentinel"
  end

  describe "drain/1 :watch — terminal continuation" do
    test "empty ready/ does not return — sleeps, then ships a pitch that arrives mid-wake", ctx do
      wakes = start_agent(0)

      sleep_fn = fn _secs ->
        n = Agent.get_and_update(wakes, fn n -> {n, n + 1} end)

        cond do
          n == 0 ->
            # Simulate an scp landing while the drain is asleep on the
            # first empty scan.
            write_pitch(ctx.ready_dir, "arrived")
            :ok

          n == 1 ->
            # "arrived" has shipped and ready/ is empty again — stop here,
            # the assertion under test (it shipped) already happened.
            raise WatchStop

          true ->
            :ok
        end
      end

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

      opts =
        shipped_opts(ctx,
          spawn_fn: spawn_fn,
          sleep_fn: sleep_fn,
          watch: true,
          mtime_fn: fn _path -> 0 end
        )

      output =
        capture_io(:stderr, fn ->
          assert_raise WatchStop, fn -> quiet_drain(opts) end
        end)

      assert output =~ "queue: watching"
      assert Agent.get(wakes, & &1) >= 2
      assert File.exists?(Path.join(ctx.shipped_dir, "arrived.md"))
    end

    test "without :watch, empty ready/ still returns immediately (default unchanged)", ctx do
      assert {:ok, 0} = quiet_drain(base_opts(ctx, []))
    end
  end

  describe "drain/1 :watch — quiescence gate" do
    test "a pitch with a fresh mtime is excluded from this scan, built once quiesced", ctx do
      write_pitch(ctx.ready_dir, "fresh")

      wakes = start_agent(0)

      # First scan sees "fresh" as mid-arrival (mtime way "in the future" of
      # now_fn's frozen clock, well inside the quiesce window). After one
      # sleep, report it as old (quiesced).
      mtime_fn = fn _path ->
        if Agent.get(wakes, & &1) == 0, do: 1_700_000_000, else: 0
      end

      sleep_fn = fn _secs ->
        n = Agent.get_and_update(wakes, fn n -> {n, n + 1} end)
        if n >= 1, do: raise(WatchStop)
        :ok
      end

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

      opts =
        shipped_opts(ctx,
          spawn_fn: spawn_fn,
          sleep_fn: sleep_fn,
          mtime_fn: mtime_fn,
          watch: true,
          quiesce_secs: 30
        )

      # First scan: "fresh" is excluded (fresh mtime) -> ready/ looks empty
      # -> watch branch sleeps (wake 0, no raise) -> second scan: "fresh"
      # now quiesced -> built and shipped -> ready/ empty again -> watch
      # branch sleeps again (wake 1) -> WatchStop.
      assert_raise WatchStop, fn -> quiet_drain(opts) end
      assert File.exists?(Path.join(ctx.shipped_dir, "fresh.md"))
    end

    test "a dependent is BLOCKED (not built) while its dep is still quiescing", ctx do
      write_pitch(ctx.ready_dir, "dep")
      write_pitch(ctx.ready_dir, "dependent", "# Pitch: dependent\n\nBlocks-on: dep\n")

      wakes = start_agent(0)
      built = start_agent([])

      # "dep" reports a fresh mtime (mid-arrival) on the FIRST scan only —
      # quiesced on every scan after. "dependent" is always old (it's a
      # small hand-authored fixture, not mid-transfer).
      mtime_fn = fn path ->
        if String.contains?(path, "dep.md") and Agent.get(wakes, & &1) == 0 do
          1_700_000_000
        else
          0
        end
      end

      sleep_fn = fn _secs ->
        Agent.update(wakes, &(&1 + 1))
        # Both pitches have shipped and ready/ is empty again by the time
        # this second sleep runs — stop the otherwise-infinite watch loop
        # right there, the assertions below are already satisfied.
        if Agent.get(built, & &1) == ["dep", "dependent"], do: raise(WatchStop)
        :ok
      end

      spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
        Agent.update(built, &(&1 ++ [slug]))
        {:exit_code, 0}
      end

      opts =
        shipped_opts(ctx,
          spawn_fn: spawn_fn,
          sleep_fn: sleep_fn,
          mtime_fn: mtime_fn,
          watch: true,
          quiesce_secs: 30
        )

      assert_raise WatchStop, fn -> quiet_drain(opts) end
      # "dep" must be built (and shipped) strictly before "dependent" — the
      # dependent must never see its dep as satisfied while quiescing.
      assert Agent.get(built, & &1) == ["dep", "dependent"]
      assert File.exists?(Path.join(ctx.shipped_dir, "dep.md"))
      assert File.exists?(Path.join(ctx.shipped_dir, "dependent.md"))
    end
  end

  describe "drain/1 :watch — Darwin keychain preflight" do
    test "locked keychain skips the spawn and keeps watching until unlocked", ctx do
      write_pitch(ctx.ready_dir, "solo")

      checks = start_agent(0)

      keychain_fn = fn ->
        n = Agent.get_and_update(checks, fn n -> {n, n + 1} end)
        n > 0
      end

      sleep_fn = fn _secs ->
        # After the pitch ships, ready/ goes empty and the watch branch
        # sleeps again — stop there once the shipped-file assertion below
        # is guaranteed reachable.
        if File.exists?(Path.join(ctx.shipped_dir, "solo.md")), do: raise(WatchStop)
        :ok
      end

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

      opts =
        shipped_opts(ctx,
          spawn_fn: spawn_fn,
          sleep_fn: sleep_fn,
          mtime_fn: fn _path -> 0 end,
          keychain_fn: keychain_fn,
          watch: true
        )

      output =
        capture_io(:stderr, fn ->
          assert_raise WatchStop, fn -> quiet_drain(opts) end
        end)

      if match?({:unix, :darwin}, :os.type()) do
        assert output =~ "queue: keychain locked"
        assert Agent.get(checks, & &1) >= 2
      else
        # Non-Darwin: the preflight never runs — keychain_fn is never
        # called, and the pitch ships on the first pass.
        assert Agent.get(checks, & &1) == 0
      end

      assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    end
  end

  # ── exit @dirty_tree_exit_code (4): committed AND retired, dirty tree ──────
  # The child already ran record_ship + moved the pitch out of ready/building
  # into shipped/ UNCONDITIONALLY before exiting — this is a SHIP, never a
  # failure. See Mix.Tasks.Codegen.Loop's @dirty_tree_exit_code and
  # codegen/pitches/shipped/a-landed-pitch-cannot-be-handed-out-again.md.
  describe "exit 4 (dirty-tree-after-retire) — shipped-with-warning, never requeued" do
    test "shipped_count increments, slug NOT in failed_slugs, warning on stderr, drain continues",
         ctx do
      # Selection reads ready_dir BEFORE the (simulated) child runs — the
      # slug must still be there at selection time. The mock spawn_fn
      # itself performs the child's unconditional retire (record_ship +
      # ready/ -> shipped/ mv), mirroring what the REAL `mix codegen.loop`
      # child does before exiting @dirty_tree_exit_code.
      write_pitch(ctx.ready_dir, "solo")

      spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
        File.rename!(
          Path.join(ctx.ready_dir, "#{slug}.md"),
          Path.join(ctx.shipped_dir, "#{slug}.md")
        )

        {:exit_code, 4}
      end

      output =
        capture_io(:stderr, fn ->
          assert {:ok, 1} = quiet_drain(base_opts(ctx, spawn_fn: spawn_fn))
        end)

      assert output =~ "solo"
      assert output =~ "COMMITTED and RETIRED"
      refute File.exists?(Path.join(ctx.ready_dir, "solo.md"))
      assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    end

    test "ship/6 finds the pitch in building/ (child committed but never shipped it itself)",
         ctx do
      building_dir = Path.join([ctx.dir, "codegen", "pitches", "building"])
      File.mkdir_p!(building_dir)
      write_pitch(ctx.ready_dir, "solo")

      # Simulate claim_pitch!/2's rename (ready/ -> building/) happening
      # INSIDE the child, at spawn time — the child committed+retired via
      # exit 4 WITHOUT itself moving building/ -> shipped/ (an edge the
      # drain's own ship/6 fallback must cover).
      spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
        File.rename!(
          Path.join(ctx.ready_dir, "#{slug}.md"),
          Path.join(building_dir, "#{slug}.md")
        )

        {:exit_code, 4}
      end

      capture_io(:stderr, fn ->
        assert {:ok, 1} =
                 quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, building_dir: building_dir))
      end)

      refute File.exists?(Path.join(building_dir, "solo.md"))
      assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    end

    test "regression: exit 5 (an unrelated nonzero) still routes to handle_nonzero_exit, not the exit-4 arm",
         ctx do
      write_pitch(ctx.ready_dir, "solo")
      transient_fn = fn _jsonl -> false end

      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 5} end

      capture_io(:stderr, fn ->
        assert {:ok, 0} =
                 quiet_drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))
      end)

      # exit 5 is a deterministic failure — the pitch stays in ready/, never
      # shipped, never removed.
      assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
      refute File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    end
  end
end

# Sibling module, async: false — holds every test in this file that mutates
# the process-global CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS env var via
# System.put_env/2. That var is read once, per-call, inside
# LoopQueueDrain.default_spawn_fn/5 (via pitch_budget_from_env/0) — any
# concurrent async: true test setting a DIFFERENT value races the read and
# can silently shrink/grow another test's timeout budget mid-flight. Moving
# every mutator here (serialized) removes the race entirely; the rest of
# LoopQueueDrainTest stays async: true.
defmodule CodegenTestHarness.LoopQueueDrainEnvSerialTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias CodegenTestHarness.LoopQueueDrain

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "loop_queue_drain_env_serial_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp start_agent(initial) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp write_script(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  # Polls for `path` to exist and be non-empty, up to `timeout_ms`. Used
  # instead of a fixed `Process.sleep/1` for asserting a concurrently
  # (backgrounded) child process has written its pidfile.
  defp wait_for_file_content(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_file_content_loop(path, deadline)
  end

  defp wait_for_file_content_loop(path, deadline) do
    case File.read(path) do
      {:ok, content} when content != "" ->
        String.trim(content)

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for #{path} to be written")
        else
          Process.sleep(20)
          wait_for_file_content_loop(path, deadline)
        end
    end
  end

  describe "default_terminal_marker_fn/1" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "loop_queue_drain_terminal_marker_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "reads a well-formed marker", %{dir: dir} do
      marker_dir = Path.join([dir, "codegen", "gate-pending"])
      File.mkdir_p!(marker_dir)

      File.write!(
        Path.join(marker_dir, "terminal-state.json"),
        Jason.encode!(%{terminal: true, reason: "gate verdict=failed", owner: "developer-static"})
      )

      assert LoopQueueDrain.default_terminal_marker_fn(dir) ==
               {:terminal, "gate verdict=failed", "developer-static"}
    end

    test "absent file -> :absent (fail-open)", %{dir: dir} do
      assert LoopQueueDrain.default_terminal_marker_fn(dir) == :absent
    end

    test "malformed JSON -> :absent (fail-open, never crashes the drain)", %{dir: dir} do
      marker_dir = Path.join([dir, "codegen", "gate-pending"])
      File.mkdir_p!(marker_dir)
      File.write!(Path.join(marker_dir, "terminal-state.json"), "not json")

      assert LoopQueueDrain.default_terminal_marker_fn(dir) == :absent
    end

    test "terminal: false -> :absent (only an explicit true claims a deterministic exhaustion)",
         %{
           dir: dir
         } do
      marker_dir = Path.join([dir, "codegen", "gate-pending"])
      File.mkdir_p!(marker_dir)

      File.write!(
        Path.join(marker_dir, "terminal-state.json"),
        Jason.encode!(%{terminal: false, reason: "", owner: nil})
      )

      assert LoopQueueDrain.default_terminal_marker_fn(dir) == :absent
    end
  end

  describe "pitch_budget_from_env/0" do
    test "unset -> 7200" do
      System.delete_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS")
      assert LoopQueueDrain.pitch_budget_from_env() == 7200
    end

    test "\"7\" -> 7" do
      System.put_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS", "7")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS") end)
      assert LoopQueueDrain.pitch_budget_from_env() == 7
    end

    test "\"0\" -> 7200 (sentinel)" do
      System.put_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS", "0")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS") end)
      assert LoopQueueDrain.pitch_budget_from_env() == 7200
    end

    test "\"x\" (non-numeric) -> 7200" do
      System.put_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS", "x")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS") end)
      assert LoopQueueDrain.pitch_budget_from_env() == 7200
    end
  end

  describe "max_retries_from_env/0" do
    test "unset -> 3" do
      System.delete_env("CODEGEN_BUILD_QUEUE_MAX_RETRIES")
      assert LoopQueueDrain.max_retries_from_env() == 3
    end

    test "\"5\" -> 5" do
      System.put_env("CODEGEN_BUILD_QUEUE_MAX_RETRIES", "5")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_MAX_RETRIES") end)
      assert LoopQueueDrain.max_retries_from_env() == 5
    end
  end

  describe "retry_delays_from_env/0" do
    test "unset -> [30, 120, 300]" do
      System.delete_env("CODEGEN_BUILD_QUEUE_RETRY_DELAYS")
      assert LoopQueueDrain.retry_delays_from_env() == [30, 120, 300]
    end

    test "\"1 2 3\" -> [1, 2, 3]" do
      System.put_env("CODEGEN_BUILD_QUEUE_RETRY_DELAYS", "1 2 3")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_RETRY_DELAYS") end)
      assert LoopQueueDrain.retry_delays_from_env() == [1, 2, 3]
    end
  end

  describe "max_consecutive_fails_from_env/0" do
    test "unset -> 3" do
      System.delete_env("CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS")
      assert LoopQueueDrain.max_consecutive_fails_from_env() == 3
    end

    test "\"5\" -> 5" do
      System.put_env("CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS", "5")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS") end)
      assert LoopQueueDrain.max_consecutive_fails_from_env() == 5
    end

    test "\"0\" -> 3 (sentinel)" do
      System.put_env("CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS", "0")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS") end)
      assert LoopQueueDrain.max_consecutive_fails_from_env() == 3
    end

    test "\"x\" (non-numeric) -> 3" do
      System.put_env("CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS", "x")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS") end)
      assert LoopQueueDrain.max_consecutive_fails_from_env() == 3
    end
  end

  describe "max_pitch_fails_from_env/0" do
    test "unset -> 2" do
      System.delete_env("CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS")
      assert LoopQueueDrain.max_pitch_fails_from_env() == 2
    end

    test "\"3\" -> 3" do
      System.put_env("CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS", "3")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS") end)
      assert LoopQueueDrain.max_pitch_fails_from_env() == 3
    end

    test "\"0\" -> 2 (sentinel)" do
      System.put_env("CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS", "0")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS") end)
      assert LoopQueueDrain.max_pitch_fails_from_env() == 2
    end

    test "\"x\" (non-numeric) -> 2" do
      System.put_env("CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS", "x")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS") end)
      assert LoopQueueDrain.max_pitch_fails_from_env() == 2
    end
  end

  describe "outage_pause_from_env/0" do
    test "unset -> 900" do
      System.delete_env("CODEGEN_BUILD_QUEUE_OUTAGE_PAUSE_SECS")
      assert LoopQueueDrain.outage_pause_from_env() == 900
    end

    test "\"120\" -> 120" do
      System.put_env("CODEGEN_BUILD_QUEUE_OUTAGE_PAUSE_SECS", "120")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_OUTAGE_PAUSE_SECS") end)
      assert LoopQueueDrain.outage_pause_from_env() == 120
    end

    test "\"0\" -> 900 (sentinel)" do
      System.put_env("CODEGEN_BUILD_QUEUE_OUTAGE_PAUSE_SECS", "0")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_OUTAGE_PAUSE_SECS") end)
      assert LoopQueueDrain.outage_pause_from_env() == 900
    end

    test "\"x\" (non-numeric) -> 900" do
      System.put_env("CODEGEN_BUILD_QUEUE_OUTAGE_PAUSE_SECS", "x")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_OUTAGE_PAUSE_SECS") end)
      assert LoopQueueDrain.outage_pause_from_env() == 900
    end
  end

  describe "queue_budget_from_env/0" do
    test "unset -> nil (unlimited, no default)" do
      System.delete_env("CODEGEN_BUILD_QUEUE_BUDGET_USD")
      assert LoopQueueDrain.queue_budget_from_env() == nil
    end

    test "\"40\" -> 40.0" do
      System.put_env("CODEGEN_BUILD_QUEUE_BUDGET_USD", "40")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_BUDGET_USD") end)
      assert LoopQueueDrain.queue_budget_from_env() == 40.0
    end

    test "\"12.50\" -> 12.5" do
      System.put_env("CODEGEN_BUILD_QUEUE_BUDGET_USD", "12.50")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_BUDGET_USD") end)
      assert LoopQueueDrain.queue_budget_from_env() == 12.5
    end

    test "\"0\" -> nil (sentinel, never a zero ceiling)" do
      System.put_env("CODEGEN_BUILD_QUEUE_BUDGET_USD", "0")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_BUDGET_USD") end)
      assert LoopQueueDrain.queue_budget_from_env() == nil
    end

    test "\"x\" (non-numeric) -> nil" do
      System.put_env("CODEGEN_BUILD_QUEUE_BUDGET_USD", "x")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_BUDGET_USD") end)
      assert LoopQueueDrain.queue_budget_from_env() == nil
    end
  end

  describe "default_spawn_fn/5 timeout" do
    test "timeout kills the child process tree via the kill_fn seam", ctx do
      sleeper =
        write_script(ctx.dir, "sleeper.sh", """
        #!/usr/bin/env bash
        echo starting
        sleep 30
        echo should-not-print
        """)

      calls = start_agent([])

      kill_fn = fn port ->
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} ->
              pid

            # fail-loud-exempt: Port.info/2 returns nil when the port is
            # already closed (process exited between spawn and this
            # kill_fn call) — a legitimate race in this test's own timing,
            # not an unexpected condition to raise on.
            nil ->
              nil
          end

        Agent.update(calls, &(&1 ++ [os_pid]))
      end

      jsonl = Path.join(ctx.dir, "out.jsonl")

      Process.put(:__queue_drain_build_bin__, sleeper)
      Process.put(:__queue_drain_kill_fn__, kill_fn)

      on_exit(fn ->
        Process.delete(:__queue_drain_build_bin__)
        Process.delete(:__queue_drain_kill_fn__)
      end)

      System.put_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS", "1")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS") end)

      capture_io(:stderr, fn ->
        send(
          self(),
          {:result, LoopQueueDrain.default_spawn_fn("slug", "claude", "phoenix", ctx.dir, jsonl)}
        )
      end)

      result =
        receive do
          {:result, r} -> r
        end

      assert result == :timeout
      assert File.exists?(jsonl)
      recorded = Agent.get(calls, & &1)
      assert length(recorded) == 1
      assert [os_pid] = recorded
      assert is_integer(os_pid)
    end
  end

  describe "default_kill_tree/1 (via __queue_drain_ps_fn__ seam)" do
    # Explicit timeout: this test's own duration (budget + await headroom)
    # exceeds ExUnit's default 60s per-test timeout.
    @tag timeout: 90_000
    test "reaps a spawned child's own subprocess grandchild via the ppid walk", ctx do
      # `parent.sh` spawns a real grandchild (`sleeper.sh`, backgrounded) then
      # sleeps itself — mirrors mix codegen.loop -> claude CLI shape. Both
      # must die once default_kill_tree walks the REAL system process table
      # (no ps_fn override here — this exercises default_ps_lister/0 for
      # real, proving the ppid walk finds true OS grandchildren that
      # `pkill -P <direct-child-only>` would miss).
      #
      # sleeper's own sleep duration (60s) MUST exceed the budget below (10s)
      # so the timeout-kill path is what ends the process — not sleeper
      # completing naturally, which would return {:exit_code, 0} instead of
      # :timeout and falsely pass/fail depending on race timing.
      grandchild_pidfile = Path.join(ctx.dir, "grandchild.pid")

      sleeper =
        write_script(ctx.dir, "sleeper.sh", """
        #!/usr/bin/env bash
        sleep 60
        """)

      parent =
        write_script(ctx.dir, "parent.sh", """
        #!/usr/bin/env bash
        "#{sleeper}" &
        echo $! > "#{grandchild_pidfile}"
        wait
        """)

      jsonl = Path.join(ctx.dir, "out.jsonl")

      # Budget (10s) must be shorter than sleeper's own sleep (60s, above) so
      # the timeout-kill path is what ends the process — and long enough,
      # relative to the grandchild-confirmation step below, that the
      # confirmation reliably completes before the kill fires even under
      # full-suite `make test` load (280 tests, many spawning real
      # subprocesses concurrently; fork+exec of a bash script has been
      # observed to take several seconds end-to-end on a contended machine).
      # This module is async: false (no other test in the suite can mutate
      # this env var concurrently). The confirm-before-timeout ordering (not
      # the specific number of seconds) is what makes this test deterministic.
      System.put_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS", "10")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS") end)

      # Run default_spawn_fn in a Task so THIS test process can poll for the
      # grandchild pidfile CONCURRENTLY with the blocking budget+kill call —
      # rather than only observing after the whole call (budget + kill_tree)
      # has already returned, which is what created the original race: the
      # timeout could fire before parent.sh was even scheduled to fork
      # sleeper.sh, leaving the pidfile never written.
      #
      # Process.put/2 is process-local — Task.async spawns a NEW process, so
      # setting :__queue_drain_build_bin__ in the test process (as the prior
      # version of this test did) is invisible inside the task. default_spawn_fn
      # then silently fell back to the real @codegen_build_bin, which exits
      # immediately with a non-zero code instead of ever running parent.sh —
      # the grandchild pidfile was never written and the test flaked/failed
      # regardless of timeout budget. Fix: put the process-dictionary entry
      # INSIDE the task closure, where default_spawn_fn's Process.get/2 runs.
      task =
        Task.async(fn ->
          Process.put(:__queue_drain_build_bin__, parent)
          ref = make_ref()

          capture_io(:stderr, fn ->
            send(
              self(),
              {ref, LoopQueueDrain.default_spawn_fn("slug", "claude", "phoenix", ctx.dir, jsonl)}
            )
          end)

          receive do
            {^ref, r} -> r
          end
        end)

      # Confirm the grandchild is alive BEFORE caring about the timeout —
      # this decouples "spawn+confirm grandchild alive" from "the timeout
      # kill fires", so the fork's OS scheduling delay can never race the
      # budget window.
      grandchild_pid = wait_for_file_content(grandchild_pidfile, 8_000)

      assert LoopQueueDrain.default_ps_lister()
             |> Enum.any?(fn {pid, _ppid} ->
               Integer.to_string(pid) == grandchild_pid
             end),
             "expected grandchild pid #{grandchild_pid} to be alive before the timeout kill"

      result = Task.await(task, 60_000)
      assert result == :timeout

      refute LoopQueueDrain.default_ps_lister()
             |> Enum.any?(fn {pid, _ppid} ->
               Integer.to_string(pid) == grandchild_pid
             end)
    end
  end
end
