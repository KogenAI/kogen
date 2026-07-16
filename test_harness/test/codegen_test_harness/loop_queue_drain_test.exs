defmodule CodegenTestHarness.LoopQueueDrainTest do
  use ExUnit.Case, async: true
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
      now_fn: fn -> 1_700_000_000 end,
      pid_alive_fn: fn _pid -> false end,
      git_head_fn: fn _cwd -> nil end,
      gate_verdict_fn: fn _cwd -> "" end,
      gate_base_sha_fn: fn _cwd -> "" end,
      # Stale by default (older than any real spawn `ts`) — never-fresh,
      # preserving the semantics of every failure-path test that doesn't
      # opt into a real gate record.
      gate_mtime_fn: fn _cwd -> 0 end,
      discover_session_log_fn: fn _cwd, _slug, _spawn_stamp -> nil end,
      blocked_fn: fn -> %{} end
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
  # The gate runs BEFORE the committer (loop role order), so a real gate
  # record's base_sha can only ever equal the head AT GATE TIME — i.e. this
  # attempt's head_before, the value git_head_fn returned on the call
  # immediately BEFORE the current (most recent) one. gate_verdict_fn/
  # gate_base_sha_fn track that PREVIOUS head value, not the latest.
  # gate_mtime_fn always reports "now" (>= the frozen now_fn), so the
  # freshness mtime leg is always satisfied here.
  #
  # SAFE for: exit-0-only sequences, and TIMEOUT-then-exit-0 sequences
  # (timeout attempts never reach handle_nonzero_exit, so its
  # committer-post-commit-hiccup ship branches are never evaluated with this
  # fixture's "clear" verdict).
  #
  # UNSAFE for: sequences with a NONZERO-exit attempt before the real
  # exit-0 ship (e.g. transient-retry-then-ship) — a nonzero attempt DOES
  # reach handle_nonzero_exit/7, which shares this same "always clear"
  # verdict and would spuriously trip its committer-post-commit-hiccup
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

    assert {:ok, 2} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
    assert Agent.get(calls, & &1) == ["a", "b"]
    refute File.exists?(Path.join(ctx.ready_dir, "a.md"))
    refute File.exists?(Path.join(ctx.ready_dir, "b.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "a.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "b.md"))
  end

  test "1b: jsonl filename uses UTC YYYYMMDD_HHMMSS stamp, not raw epoch", ctx do
    write_pitch(ctx.ready_dir, "solo")

    jsonl_path = start_agent(nil)

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      Agent.update(jsonl_path, fn _ -> jsonl end)
      {:exit_code, 0}
    end

    assert {:ok, 1} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))

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
        assert {:ok, 1} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      end)

    assert output =~ ~r/\[1\/1\] solo \.\.\. building/
  end

  test "1d: idx/total computed once across 2 pitches (b Blocks-on a)", ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b", "# Pitch: b\n\nBlocks-on: a\n")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 2} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
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
                 LoopQueueDrain.drain(
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
                 LoopQueueDrain.drain(
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

    assert {:ok, 0} = LoopQueueDrain.drain(base_opts(ctx, []))

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

    assert {:ok, 0} = LoopQueueDrain.drain(base_opts(ctx, []))

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
    File.write!(Path.join(aging_transcript_dir, "01-planner-phoenix.jsonl"), "planner turn\n")
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

    assert {:ok, 0} = LoopQueueDrain.drain(base_opts(ctx, []))

    refute File.exists?(old_cycle)
    assert File.exists?(old_cycle <> ".gz")
    refute File.exists?(session_md)
    refute File.exists?(failure_dump)
    refute File.exists?(ancient_transcript_dir)
    assert File.dir?(aging_transcript_dir)

    assert File.exists?(Path.join(aging_transcript_dir, "01-planner-phoenix.jsonl.gz"))
    refute File.exists?(Path.join(aging_transcript_dir, "01-planner-phoenix.jsonl"))
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
        assert {:ok, 0} = LoopQueueDrain.drain(base_opts(ctx, []))
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
                 LoopQueueDrain.drain(
                   base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn)
                 )
      end)

    assert output =~ "boom"
    assert output =~ "session_id: sess-123"
    assert output =~ ~r/\[1\/1\] solo \.\.\. FAILED/
    assert output =~ "queue: FAILED bucket: solo"
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
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
      LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
    end
  end

  # ── 3. Ship-success ─────────────────────────────────────────────────────

  test "3: ship-success — child exit 0 moves ready -> shipped", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    assert {:ok, 1} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
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

      assert {:ok, 1} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      refute File.exists?(Path.join(ctx.ready_dir, "solo.md"))
      assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    end

    test "fallback: agent left pitch in ready/ -> drain moves it", ctx do
      write_pitch(ctx.ready_dir, "solo")

      # non-compliant agent: exits 0 but never ships (leaves ready/<slug>.md).
      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

      assert {:ok, 1} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
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
        LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      end
    end
  end

  # ── 4. Transient failure -> retry -> ship ───────────────────────────────

  test "4: transient failure retries once with backoff then ships", ctx do
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
    # handle_nonzero_exit/7's committer-post-commit-hiccup branch would ship
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
             LoopQueueDrain.drain(
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
    assert Agent.get(sleeps, & &1) == [30]
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  # ── 5. Transient exhausted -> skip-and-continue (isolated failure) ──────

  test "5: transient exhausted after max_retries skips-and-continues, left in ready/", ctx do
    write_pitch(ctx.ready_dir, "solo")

    sleeps = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> true end
    sleep_fn = fn secs -> Agent.update(sleeps, &(&1 ++ [secs])) end

    assert {:ok, 0} =
             LoopQueueDrain.drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 transient_fn: transient_fn,
                 sleep_fn: sleep_fn,
                 max_retries: 2
               )
             )

    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    assert length(Agent.get(sleeps, & &1)) == 2
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
                 LoopQueueDrain.drain(
                   base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn)
                 )
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
             LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))

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
    # committer-post-commit-hiccup branch would ship them anyway.
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
             LoopQueueDrain.drain(
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
             LoopQueueDrain.drain(
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
             LoopQueueDrain.drain(
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
    # handle_nonzero_exit's committer-post-commit-hiccup branch would ship it
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
                 LoopQueueDrain.drain(
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

  # ── 6r. Committer-post-commit-hiccup recovery ───────────────────────────

  test "6r1: committed + gate-clear + already-in-shipped counts shipped, no re-ship", ctx do
    write_pitch(ctx.ready_dir, "solo")

    head_calls = start_agent([])

    git_head_fn = fn cwd ->
      n = Agent.get_and_update(head_calls, fn calls -> {length(calls), calls ++ [cwd]} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    spawn_fn = fn slug, _h, _s, cwd, _jsonl ->
      # simulate the agent's own committer having already shipped the pitch
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
             LoopQueueDrain.drain(
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
             LoopQueueDrain.drain(
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
             LoopQueueDrain.drain(
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
             LoopQueueDrain.drain(
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
             LoopQueueDrain.drain(
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
    # fix this would match the committer-post-commit-hiccup branch and ship.
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
                 LoopQueueDrain.drain(
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
                 LoopQueueDrain.drain(
                   base_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn)
                 )

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
      assert {:error, _reason} = LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
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
             LoopQueueDrain.drain(
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
             LoopQueueDrain.drain(
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
             LoopQueueDrain.drain(
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
                 LoopQueueDrain.drain(
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
                 LoopQueueDrain.drain(
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

    # Committer-post-commit-hiccup shape: nonzero exit, but the pitch is
    # already in shipped/ (agent's own committer ran) — this is exactly the
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
             LoopQueueDrain.drain(
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
             LoopQueueDrain.drain(
               shipped_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn)
             )

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
             LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn))

    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    assert length(Agent.get(stash_calls, & &1)) == 2
  end

  test "8b: timeout-twice-skip advances to ship other pitches", ctx do
    write_pitch(ctx.ready_dir, "bad")
    write_pitch(ctx.ready_dir, "good")

    spawn_fn = fn slug, _h, _s, _cwd, _jsonl ->
      if slug == "bad", do: :timeout, else: {:exit_code, 0}
    end

    assert {:ok, 1} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
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
                 LoopQueueDrain.drain(
                   shipped_opts(ctx, spawn_fn: spawn_fn, blocked_fn: blocked_fn)
                 )
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
             LoopQueueDrain.drain(
               shipped_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn)
             )
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
             LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn))

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
             LoopQueueDrain.drain(
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
             LoopQueueDrain.drain(
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
             LoopQueueDrain.drain(
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
                 LoopQueueDrain.drain(
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

    assert {:ok, branch} = LoopQueueDrain.default_git_stash_fn(ctx.dir, "myslug", "fail")
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
             LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn, pid_alive_fn: pid_alive_fn))

    assert reason =~ "already running"
    assert File.exists?(Path.join(ctx.ready_dir, "solo.md"))
  end

  test "10b: stale (dead-pid) lock is reclaimed and drain proceeds", ctx do
    File.write!(ctx.lock_path, "99999 queue\n")
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end
    pid_alive_fn = fn _pid -> false end

    assert {:ok, 1} =
             LoopQueueDrain.drain(
               shipped_opts(ctx, spawn_fn: spawn_fn, pid_alive_fn: pid_alive_fn)
             )

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

    assert {:ok, 1} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
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

    assert {:error, reason} = LoopQueueDrain.drain(opts)
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

    assert {:ok, 2} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
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
                 LoopQueueDrain.drain(
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
                 LoopQueueDrain.drain(
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
    # "failed (retrying)" line and the later "shipped" line read "[1/1]".
    assert output =~ "[1/1] solo ... failed (retrying)"
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

    test "pi -> empty string" do
      assert LoopQueueDrain.mention_prefix("pi") == ""
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

    test "pi -> bare absolute path" do
      assert LoopQueueDrain.pitch_arg_for("x", "pi", "/repo") ==
               "/repo/codegen/pitches/ready/x.md"
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

      assert {:error, reason} = LoopQueueDrain.drain(opts)
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

      assert {:ok, 1} = LoopQueueDrain.drain(opts)
    end

    test "default_build_orphan_scan/1 excludes this process's own OS pid" do
      # Sanity: the real scan never matches a nonexistent pattern in this
      # test's own cwd (no codegen-build process is bound to a random tmp
      # dir path), so it degrades to [] rather than falsely refusing.
      random_cwd = "/tmp/never-a-real-cwd-#{:erlang.unique_integer([:positive])}"
      assert LoopQueueDrain.default_build_orphan_scan(random_cwd) == []
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
                 LoopQueueDrain.drain(
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
    assert output =~ "queue: 1 shipped, 0 failed, $3.75 total"
  end

  test "(d2) no-cap control: report still prints total with no ceiling set", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      File.write!(jsonl, ~s({"type":"result","total_cost_usd":0.42}\n))
      {:exit_code, 0}
    end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      end)

    assert output =~ "queue: 1 shipped, 0 failed, $0.42 total"
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
                 LoopQueueDrain.drain(
                   shipped_opts(ctx, spawn_fn: spawn_fn, queue_budget_usd: 10.0)
                 )

        assert reason =~ "spend ceiling reached"
        assert reason =~ "$12.00"
        assert reason =~ "$10.00"
        assert reason =~ "c"
      end)

    # Exactly two spawns — the third pitch never launches.
    assert Agent.get(calls, & &1) == ["a", "b"]
    assert output =~ "queue: 2 shipped, 0 failed, $12.00 total"

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
                 LoopQueueDrain.drain(
                   shipped_opts(ctx, spawn_fn: spawn_fn, queue_budget_usd: 10.0)
                 )

        assert reason =~ "cannot account for"
        assert reason =~ "no result record"
      end)

    # Only the first pitch ever spawns — the drain halts before "b".
    assert Agent.get(calls, & &1) == ["a"]
    assert output =~ "queue: 1 shipped, 0 failed, unknown (unaccountable child spend) total"
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
        assert {:ok, 2} = LoopQueueDrain.drain(shipped_opts(ctx, spawn_fn: spawn_fn))
      end)

    assert output =~ "queue: 2 shipped, 0 failed, unknown (unaccountable child spend) total"
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
