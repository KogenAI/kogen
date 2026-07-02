defmodule CodegenTestHarness.LoopQueueDrainTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.LoopQueueDrain

  setup do
    dir = Path.join(System.tmp_dir!(), "loop_queue_drain_test_#{:erlang.unique_integer([:positive])}")
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
      pid_alive_fn: fn _pid -> false end
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
             LoopQueueDrain.drain(
               base_opts(ctx, spawn_fn: spawn_fn, pid_alive_fn: pid_alive_fn)
             )

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
               base_opts(ctx, spawn_fn: spawn_fn, pid_alive_fn: pid_alive_fn)
             )

    assert File.exists?(Path.join(ctx.shipped_dir, "solo.md"))
    refute File.exists?(ctx.lock_path)
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

  # ── Env-mutating tests above use System.put_env/delete_env (process-global) —
  # keep this module async: true (no shared queue.lock/ready state), but note
  # a sibling async: false module would be required if these env mutations
  # ever raced with a concurrently-running test reading the same keys. None
  # of the drain/1 filesystem tests read these env vars (opts override them),
  # so no race exists today.
end
