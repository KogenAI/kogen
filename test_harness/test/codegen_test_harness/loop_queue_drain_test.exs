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
      git_stash_fn: fn _cwd, _slug -> :ok end,
      now_fn: fn -> 1_700_000_000 end,
      pid_alive_fn: fn _pid -> false end,
      git_head_fn: fn _cwd -> nil end,
      gate_verdict_fn: fn _cwd -> "" end,
      discover_session_log_fn: fn _cwd, _slug, _spawn_stamp -> nil end,
      blocked_fn: fn -> %{} end
    ]

    Keyword.merge(defaults, extra)
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

    assert {:ok, 2} = LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
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

    assert {:ok, 1} = LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))

    captured = Agent.get(jsonl_path, & &1)
    assert Path.basename(captured) == "20231114_221320_solo_build.jsonl"
    assert Path.basename(captured) =~ ~r/^[0-9]{8}_[0-9]{6}_/
  end

  # ── 1c. Progress banner / two-path echo / terminal lines ────────────────

  test "1c: banner emits [1/1] slug ... building", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} = LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
      end)

    assert output =~ ~r/\[1\/1\] solo \.\.\. building/
  end

  test "1d: idx/total computed once across 2 pitches (b Blocks-on a)", ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b", "# Pitch: b\n\nBlocks-on: a\n")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 2} = LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
      end)

    assert output =~ "[1/2] a ... building"
    assert output =~ "[2/2] b ... building"
  end

  test "1e: single-path echo — discover_session_log_fn result is ignored (same artifact)", ctx do
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
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     discover_session_log_fn: discover_session_log_fn
                   )
                 )
      end)

    # Storage format flip: discover_session_log_fn now resolves the SAME
    # artifact the `jsonl` var already holds — the md-then-jsonl fallback
    # collapses to a single echoed path (the seam's stubbed return is
    # ignored; only the real jsonl path is printed).
    refute output =~ "/path/solo_cycle.jsonl"
    assert output =~ Path.basename(Agent.get(jsonl_path, & &1))
  end

  test "1f: single-path echo — discover_session_log_fn absent still echoes jsonl alone", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

    output =
      capture_io(:stderr, fn ->
        assert {:ok, 1} =
                 LoopQueueDrain.drain(
                   base_opts(ctx,
                     spawn_fn: spawn_fn,
                     discover_session_log_fn: fn _, _, _ -> nil end
                   )
                 )
      end)

    refute output =~ "_session.md"
    assert output =~ "_solo_build.jsonl"
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

  test "1h: failure diagnostics on halt — result/session_id surfaced, FAILED line emitted", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, jsonl ->
      File.write!(jsonl, ~s({"type":"result","result":"boom","session_id":"sess-123"}\n))
      {:exit_code, 1}
    end

    transient_fn = fn _jsonl -> false end

    output =
      capture_io(:stderr, fn ->
        assert {:error, _reason} =
                 LoopQueueDrain.drain(
                   base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn)
                 )
      end)

    assert output =~ "boom"
    assert output =~ "session_id: sess-123"
    assert output =~ ~r/\[1\/1\] solo \.\.\. FAILED/
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

    assert {:ok, 1} = LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
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

      assert {:ok, 1} = LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
      refute File.exists?(Path.join(ctx.ready_dir, "solo.md"))
      assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    end

    test "fallback: agent left pitch in ready/ -> drain moves it", ctx do
      write_pitch(ctx.ready_dir, "solo")

      # non-compliant agent: exits 0 but never ships (leaves ready/<slug>.md).
      spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 0} end

      assert {:ok, 1} = LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
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
        LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
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

    transient_fn = fn _jsonl -> true end
    sleep_fn = fn secs -> Agent.update(sleeps, &(&1 ++ [secs])) end

    assert {:ok, 1} =
             LoopQueueDrain.drain(
               base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn, sleep_fn: sleep_fn)
             )

    assert Agent.get(attempts, & &1) == 2
    assert Agent.get(sleeps, & &1) == [30]
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  # ── 5. Transient exhausted -> halt loud ─────────────────────────────────

  test "5: transient exhausted after max_retries halts loud, left in ready/", ctx do
    write_pitch(ctx.ready_dir, "solo")

    sleeps = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> true end
    sleep_fn = fn secs -> Agent.update(sleeps, &(&1 ++ [secs])) end

    assert {:error, _reason} =
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

  # ── 6. Deterministic failure -> halt loud immediately ───────────────────

  test "6: deterministic failure halts immediately, remaining pitches stay in ready/", ctx do
    write_pitch(ctx.ready_dir, "a")
    write_pitch(ctx.ready_dir, "b")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> false end

    assert {:error, _reason} =
             LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn, transient_fn: transient_fn))

    assert File.exists?(Path.join(ctx.ready_dir, "a.md"))
    assert File.exists?(Path.join(ctx.ready_dir, "b.md"))
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

    assert {:ok, 1} =
             LoopQueueDrain.drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn
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

    assert {:ok, 1} =
             LoopQueueDrain.drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn
               )
             )

    refute File.exists?(Path.join(ctx.ready_dir, "solo.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "6r3: gate-clear + HEAD-unmoved retries, ships on 2nd spawn", ctx do
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

    # HEAD never moves -> committed? stays false every call
    git_head_fn = fn _cwd -> "aaa" end
    gate_verdict_fn = fn _cwd -> "clear" end
    transient_fn = fn _jsonl -> false end
    sleep_fn = fn secs -> Agent.update(sleeps, &(&1 ++ [secs])) end

    assert {:ok, 1} =
             LoopQueueDrain.drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 gate_verdict_fn: gate_verdict_fn,
                 transient_fn: transient_fn,
                 sleep_fn: sleep_fn
               )
             )

    assert Agent.get(attempts, & &1) == 2
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  test "6r4: gate-failed + nonzero + HEAD-moved halts loud, stays in ready/", ctx do
    write_pitch(ctx.ready_dir, "solo")

    head_calls = start_agent(0)

    git_head_fn = fn _cwd ->
      n = Agent.get_and_update(head_calls, fn n -> {n, n + 1} end)
      if n == 0, do: "aaa", else: "bbb"
    end

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    gate_verdict_fn = fn _cwd -> "failed" end
    transient_fn = fn _jsonl -> false end

    assert {:error, _reason} =
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

  test "6r5: not-a-repo (nil head) + nonzero + non-transient halts loud (unchanged)", ctx do
    write_pitch(ctx.ready_dir, "solo")

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> {:exit_code, 1} end
    transient_fn = fn _jsonl -> false end

    assert {:error, _reason} =
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

  test "6r6: transient nonzero (no commit, gate empty) retries unchanged, recovery seams do not fire",
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

    assert {:ok, 1} =
             LoopQueueDrain.drain(
               base_opts(ctx,
                 spawn_fn: spawn_fn,
                 git_head_fn: git_head_fn,
                 transient_fn: transient_fn
               )
             )

    assert Agent.get(attempts, & &1) == 2
    # git_head_fn called once per run_slug invocation (pre-spawn), never used
    # for a recovery decision since it's always nil here
    assert Agent.get(head_calls, & &1) == [ctx.dir, ctx.dir]
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

    git_stash_fn = fn cwd, slug ->
      Agent.update(stash_calls, &(&1 ++ [{cwd, slug}]))
      :ok
    end

    assert {:ok, 1} =
             LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn))

    assert Agent.get(stash_calls, & &1) == [{ctx.dir, "solo"}]
    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
  end

  # ── 8. Timeout twice -> skip for run ────────────────────────────────────

  test "8: timeout twice skips slug for the run, left in ready/", ctx do
    write_pitch(ctx.ready_dir, "solo")

    stash_calls = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> :timeout end

    git_stash_fn = fn cwd, slug ->
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

    assert {:ok, 1} = LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
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
                 LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn, blocked_fn: blocked_fn))
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

    git_stash_fn = fn _cwd, _slug -> {:error, :not_a_repo} end

    assert {:ok, 1} =
             LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn))
  end

  test "9b: real-ish git_stash_fn label format queue-timeout:<slug>:<ts>", ctx do
    write_pitch(ctx.ready_dir, "solo")

    labels = start_agent([])

    spawn_fn = fn _slug, _h, _s, _cwd, _jsonl -> :timeout end

    git_stash_fn = fn _cwd, slug ->
      Agent.update(labels, &(&1 ++ ["queue-timeout:#{slug}:1700000000"]))
      :ok
    end

    assert {:ok, 0} =
             LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn, git_stash_fn: git_stash_fn))

    assert Agent.get(labels, & &1) == [
             "queue-timeout:solo:1700000000",
             "queue-timeout:solo:1700000000"
           ]
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
             LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn, pid_alive_fn: pid_alive_fn))

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

    assert {:ok, 1} = LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
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

    assert {:ok, 2} = LoopQueueDrain.drain(base_opts(ctx, spawn_fn: spawn_fn))
    assert File.exists?(Path.join(ctx.shipped_dir, "a.md"))
    assert File.exists?(Path.join(ctx.shipped_dir, "c.md"))
  end

  # ── 12. Budget default resolution ───────────────────────────────────────

  describe "pitch_budget_from_env/0" do
    test "unset -> 3600" do
      System.delete_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS")
      assert LoopQueueDrain.pitch_budget_from_env() == 3600
    end

    test "\"7\" -> 7" do
      System.put_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS", "7")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS") end)
      assert LoopQueueDrain.pitch_budget_from_env() == 7
    end

    test "\"0\" -> 3600 (sentinel)" do
      System.put_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS", "0")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS") end)
      assert LoopQueueDrain.pitch_budget_from_env() == 3600
    end

    test "\"x\" (non-numeric) -> 3600" do
      System.put_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS", "x")
      on_exit(fn -> System.delete_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS") end)
      assert LoopQueueDrain.pitch_budget_from_env() == 3600
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
            {:os_pid, pid} -> pid
            _ -> nil
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
  end
end
