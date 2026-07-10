defmodule CodegenTestHarness.LoopQueueDrain do
  @moduledoc """
  Multi-pitch drain over `codegen/pitches/ready/`: reproduces
  `harnesses/shared/build-queue.sh`'s process contract on top of the shipped
  Elixir loop. Spawns one fresh `codegen-build` child per ordered pitch
  (zero cross-pitch context accumulation), transient-retries with backoff,
  enforces a per-pitch wall-clock budget/watchdog, stashes a dirty tree on
  timeout, and moves `ready/<slug>.md` to `shipped/<slug>.md` on child exit 0.

  Wires `CodegenTestHarness.LoopQueue.ordered_slugs/1` (topo-order,
  raise-on-cycle) and `LoopQueue.transient?/1` (JSONL classify) live — both
  were previously unreachable from any runtime caller.

  Old `build-queue.sh` `build-queue.json` position-manifest concerns are
  superseded by the child's exit code (0 = shipped, non-zero = not shipped).
  `is_gate_green`/committed-but-nonzero recovery (legacy `build-queue.sh`
  lines 529, 546-551, 554) IS ported — see `git_head_fn`/`gate_verdict_fn`
  below: a committer-post-commit hiccup (child exits non-zero after HEAD
  already moved and the gate verdict is `"clear"`) ships or counts the
  pitch as shipped instead of halting the whole queue.

  Timeout is handled SEPARATELY from transient-retry classification: a
  watchdog timeout always stashes + retries-once + skips-on-second, and is
  never routed through `transient?/1` (mirrors old build-queue.sh where the
  timeout branch `continue`s before the transient-check block).

  A ready pitch whose dependency (`blocks_on:` YAML frontmatter list, or
  legacy `Blocks-on:` prose when no frontmatter is present — see
  `LoopQueue.parse_edges/2`) is unsatisfied (dep in draft/ or absent
  entirely — see `LoopQueue.blocked_by_unmet_dep/2`) is a SELECTION-time
  gate: it is never selected, left physically in `ready_dir`, skipped on
  every subsequent scan, and surfaced as a distinct SKIPPED (unmet dep)
  bucket — separate from the timeout bucket. This is NOT a build failure;
  the run still completes `{:ok, shipped_count}`.
  """

  alias CodegenTestHarness.LoopQueue

  @type drain_opts :: keyword()

  @default_max_retries 3
  @default_retry_delays [30, 120, 300]
  # Retention window for `codegen/logging/*_build.log` console captures —
  # ephemeral gitignored build-forensics; never applied to `*_cycle.jsonl`
  # (the canonical, durable per-role session logs).
  @build_log_retention_secs 7 * 24 * 3600
  @default_pitch_budget_secs 3600

  @codegen_build_bin Path.expand("../../../codegen-build", __DIR__)

  @doc """
  Drains `<cwd>/codegen/pitches/ready/` for `opts[:harness]`/`opts[:stack]`/
  `opts[:cwd]`. Returns `{:ok, shipped_count}` once `ready/` empties (either
  on the first scan — nothing to do — or after shipping every pitch that
  isn't left behind by a deterministic failure/skip). Returns
  `{:error, reason}` on a deterministic child failure, exhausted transient
  retries, or lock contention.

  Lets a dependency-cycle raise from `ordered_fn` (default
  `LoopQueue.ordered_slugs/1`) propagate uncaught — crash loud, never picks
  an arbitrary order.

  `opts` (all required unless noted; `_fn` seams default to the real
  implementation, override for tests):

    * `:harness` — `"claude"` | `"pi"` (required)
    * `:stack` — stack name, e.g. `"phoenix"` (required)
    * `:cwd` — project directory the drain operates in (required)
    * `:ready_dir` — default `Path.join([cwd, "codegen", "pitches", "ready"])`
    * `:shipped_dir` — default `Path.join([cwd, "codegen", "pitches", "shipped"])`
    * `:lock_path` — default `Path.join([cwd, "codegen", "gate-pending", "queue.lock"])`
    * `:max_retries` — default 3 (env `CODEGEN_BUILD_QUEUE_MAX_RETRIES`)
    * `:retry_delays` — default `[30, 120, 300]` (env `CODEGEN_BUILD_QUEUE_RETRY_DELAYS`)
    * `:pitch_budget_secs` — default 3600 (env `CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS`)
    * `:spawn_fn` — `(slug, harness, stack, cwd, jsonl_path -> {:exit_code, integer} | :timeout)`
    * `:sleep_fn` — `(secs -> :ok)`
    * `:git_stash_fn` — `(cwd, slug -> :ok | {:error, reason})`
    * `:now_fn` — `(-> integer unix secs)`
    * `:ordered_fn` — `(ready_dir -> [slug])`, default `LoopQueue.ordered_slugs/1`
    * `:transient_fn` — `(jsonl_path -> boolean)`, default `LoopQueue.transient?/1`
    * `:blocked_fn` — `(-> %{slug => dep})`, default zero-arg closure binding
      `{ready_dir, shipped_dir}` into `LoopQueue.blocked_by_unmet_dep/2`.
      Recomputed on every scan (mirrors legacy `build-queue.sh`'s re-scan
      per iteration). A slug present in the returned map is BLOCKED — left
      in `ready_dir`, skipped for the remainder of this run, surfaced once
      as a `SKIPPED (unmet dep ...)` stderr line, never reaches `run_slug/3`.
    * `:pid_alive_fn` — `(pid -> boolean)`, default checks `/proc`-independent
      via `System.cmd("kill", ["-0", pid])` exit status
    * `:git_head_fn` — `(cwd -> String.t() | nil)`, default reads
      `git rev-parse HEAD`; `nil` when not a git repo (fail-open)
    * `:git_ancestor_fn` — `(cwd, ancestor, descendant -> boolean)`, default
      runs `git merge-base --is-ancestor`; used by the orphan-halt backstop
      to detect a HEAD-moving `git reset` that dropped the cycle base
    * `:gate_verdict_fn` — `(cwd -> String.t())`, default reads
      `codegen/gate-pending/gate-result.json` `.verdict`; `""` when absent
  """
  @spec drain(drain_opts()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def drain(opts) do
    harness = Keyword.fetch!(opts, :harness)
    stack = Keyword.fetch!(opts, :stack)
    cwd = Keyword.fetch!(opts, :cwd)

    ready_dir = Keyword.get(opts, :ready_dir, Path.join([cwd, "codegen", "pitches", "ready"]))

    shipped_dir =
      Keyword.get(opts, :shipped_dir, Path.join([cwd, "codegen", "pitches", "shipped"]))

    lock_path =
      Keyword.get(opts, :lock_path, Path.join([cwd, "codegen", "gate-pending", "queue.lock"]))

    File.mkdir_p!(ready_dir)
    File.mkdir_p!(shipped_dir)
    File.mkdir_p!(Path.dirname(lock_path))

    pid_alive_fn = Keyword.get(opts, :pid_alive_fn, &default_pid_alive?/1)

    case acquire_lock(lock_path, pid_alive_fn) do
      :ok ->
        try do
          # leg 1: clear any stale legacy build-queue.json manifest left by the
          # now-removed legacy build-queue.sh drainer. The Elixir loop never
          # writes this file; the shared lock (see :lock_path default)
          # guarantees no legacy drain is concurrently mid-run relying on it.
          # Ignore {:error, :enoent} (absent is the normal case).
          File.rm(Path.join([cwd, "codegen", "gate-pending", "build-queue.json"]))

          # Best-effort: bound the aggregate footprint of console captures.
          # Never touches `*_cycle.jsonl` (canonical session logs). A failed
          # cleanup (permission error, race) must never abort the drain.
          prune_old_build_logs(cwd)

          state = %{
            harness: harness,
            stack: stack,
            cwd: cwd,
            ready_dir: ready_dir,
            shipped_dir: shipped_dir,
            max_retries: Keyword.get(opts, :max_retries, max_retries_from_env()),
            retry_delays: Keyword.get(opts, :retry_delays, retry_delays_from_env()),
            pitch_budget_secs: Keyword.get(opts, :pitch_budget_secs, pitch_budget_from_env()),
            spawn_fn: Keyword.get(opts, :spawn_fn, &default_spawn_fn/5),
            sleep_fn: Keyword.get(opts, :sleep_fn, &default_sleep_fn/1),
            git_stash_fn: Keyword.get(opts, :git_stash_fn, &default_git_stash_fn/2),
            now_fn: Keyword.get(opts, :now_fn, &default_now_fn/0),
            ordered_fn: Keyword.get(opts, :ordered_fn, &LoopQueue.ordered_slugs/1),
            transient_fn: Keyword.get(opts, :transient_fn, &LoopQueue.transient?/1),
            blocked_fn:
              Keyword.get(opts, :blocked_fn, fn ->
                LoopQueue.blocked_by_unmet_dep(ready_dir, shipped_dir)
              end),
            git_head_fn: Keyword.get(opts, :git_head_fn, &default_git_head_fn/1),
            git_ancestor_fn: Keyword.get(opts, :git_ancestor_fn, &default_git_ancestor_fn/3),
            gate_verdict_fn: Keyword.get(opts, :gate_verdict_fn, &default_gate_verdict_fn/1),
            discover_session_log_fn:
              Keyword.get(opts, :discover_session_log_fn, &default_discover_session_log/3),
            timed_out_slugs: MapSet.new(),
            blocked_printed: MapSet.new(),
            retry_count: 0,
            last_slug: nil,
            # Computed ONCE on first scan (mirrors legacy build-queue.sh:356-358
            # "Set total on first scan only"). A pitch written mid-run as a
            # side-effect (see test 11) is NOT reflected in `total` — this is
            # intentional legacy parity, not a bug: legacy's TOTAL has the
            # identical "may understate after refill" caveat (build-queue.sh:355).
            total: length(Keyword.get(opts, :ordered_fn, &LoopQueue.ordered_slugs/1).(ready_dir))
          }

          run_loop(state, 0)
        after
          release_lock(lock_path)
        end

      {:error, _reason} = err ->
        err
    end
  end

  # ── Lock ──────────────────────────────────────────────────────────────────

  defp acquire_lock(lock_path, pid_alive_fn) do
    case File.read(lock_path) do
      {:ok, content} ->
        case String.split(String.trim(content), " ", parts: 2) do
          [pid_str | _] when pid_str != "" ->
            if pid_alive_fn.(pid_str) do
              {:error,
               "queue: a build is already running (pid #{pid_str}) — refusing to start a second"}
            else
              write_lock(lock_path)
            end

          _ ->
            write_lock(lock_path)
        end

      {:error, _reason} ->
        write_lock(lock_path)
    end
  end

  defp write_lock(lock_path) do
    File.write!(lock_path, "#{System.pid()} queue\n")
    :ok
  end

  defp release_lock(lock_path) do
    File.rm(lock_path)
    :ok
  end

  # fail-loud-exempt: best-effort cleanup of an ephemeral gitignored
  # scratch artifact (codegen/logging/*_build.log). A stat/rm failure here
  # (permission race, concurrent removal, mid-run truncation) must never
  # abort the drain — mirrors the pre-existing leg-1 File.rm(build-queue.json)
  # above, which already ignores its return for the identical reason.
  defp prune_old_build_logs(cwd) do
    cutoff = System.system_time(:second) - @build_log_retention_secs

    [cwd, "codegen", "logging", "*_build.log"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.each(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} when mtime < cutoff -> File.rm(path)
        {:ok, %{mtime: _mtime}} -> :ok
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  defp default_pid_alive?(pid_str) do
    case Integer.parse(pid_str) do
      {pid, ""} ->
        case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_out, 0} -> true
          {_out, _} -> false
        end

      _ ->
        false
    end
  end

  # ── Main loop ─────────────────────────────────────────────────────────────

  defp run_loop(state, shipped_count) do
    ordered = state.ordered_fn.(state.ready_dir)
    blocked = state.blocked_fn.()

    state = print_new_blocked(state, blocked)

    remaining =
      Enum.reject(ordered, fn slug ->
        MapSet.member?(state.timed_out_slugs, slug) or Map.has_key?(blocked, slug)
      end)

    case remaining do
      [] ->
        if map_size(blocked) > 0 do
          IO.puts(
            :stderr,
            "queue: SKIPPED (unmet dep) bucket: " <>
              Enum.map_join(blocked, ", ", fn {slug, dep} -> "#{slug} (dep #{dep})" end)
          )
        end

        {:ok, shipped_count}

      [slug | _] ->
        run_slug(state, slug, shipped_count)
    end
  end

  # Print a SKIPPED line once per NEWLY-blocked slug (mirrors legacy
  # build-queue.sh: print only when the slug is first added, not on every
  # re-scan). Returns updated state with blocked_printed extended.
  defp print_new_blocked(state, blocked) do
    Enum.reduce(blocked, state, fn {slug, dep}, acc ->
      if MapSet.member?(acc.blocked_printed, slug) do
        acc
      else
        IO.puts(:stderr, "#{slug} ... SKIPPED (unmet dep #{dep}) — left in ready/, advancing")
        %{acc | blocked_printed: MapSet.put(acc.blocked_printed, slug)}
      end
    end)
  end

  defp run_slug(state, slug, shipped_count) do
    idx = shipped_count + 1
    ts = state.now_fn.()
    stamp = Calendar.strftime(DateTime.from_unix!(ts), "%Y%m%d_%H%M%S")
    jsonl = Path.join([state.cwd, "codegen", "logging", "#{stamp}_#{slug}_build.log"])
    File.mkdir_p!(Path.dirname(jsonl))

    IO.puts(:stderr, "[#{idx}/#{state.total}] #{slug} ... building")

    head_before = state.git_head_fn.(state.cwd)

    result = state.spawn_fn.(slug, state.harness, state.stack, state.cwd, jsonl)

    echo_paths(state, slug, stamp, jsonl)

    case result do
      {:exit_code, 0} ->
        ship(state.ready_dir, state.shipped_dir, slug)
        IO.puts(:stderr, "[#{idx}/#{state.total}] #{slug} ... shipped")
        state = %{state | retry_count: 0, last_slug: nil}
        run_loop(state, shipped_count + 1)

      {:exit_code, _n} ->
        handle_nonzero_exit(state, slug, jsonl, head_before, shipped_count, idx)

      :timeout ->
        handle_timeout(state, slug, shipped_count, idx)
    end
  end

  # Two-path echo: the discovered `_cycle.jsonl` (the real per-role session
  # log, primary) is a DIFFERENT artifact from `jsonl` (the raw
  # stdout+stderr console capture of the child `codegen-build`, secondary,
  # `_build.log`). Session log is fail-open display — when not yet
  # discovered (nil), only the build log is echoed.
  defp echo_paths(state, slug, spawn_stamp, jsonl) do
    session = state.discover_session_log_fn.(state.cwd, slug, spawn_stamp)
    if session, do: IO.puts(:stderr, "  session log: " <> session)
    IO.puts(:stderr, "  build log:   " <> jsonl)
  end

  defp ship(ready_dir, shipped_dir, slug) do
    src = Path.join(ready_dir, "#{slug}.md")
    dst = Path.join(shipped_dir, "#{slug}.md")

    cond do
      # agent did not ship (non-compliant) -> drain ships as fallback
      File.exists?(src) -> File.rename!(src, dst)
      # agent already shipped (normal exit-0 path) -> no-op
      File.exists?(dst) -> :ok
      # genuine anomaly: pitch in neither dir -> fail loud, name the slug
      true -> raise "LoopQueueDrain.ship: #{slug} in neither ready/ nor shipped/"
    end

    :ok
  end

  defp handle_nonzero_exit(state, slug, jsonl, head_before, shipped_count, idx) do
    known_base? = head_before != nil and head_before != ""
    # Only re-read HEAD when there is a known base to compare against — mirrors
    # the pre-existing short-circuit (`head_before != nil and head_before !=
    # "" and ...`) so a nil/empty head_before never triggers an extra
    # git_head_fn call.
    head_after = if known_base?, do: state.git_head_fn.(state.cwd), else: nil
    head_moved? = known_base? and head_after != head_before

    # Orphan check: HEAD moved AND head_before is no longer an ancestor of the
    # new HEAD. This is the same ancestry-blindness bug class as
    # `OrchestrationLoop.assert_work_produced!` — a HEAD-moving `git reset`
    # (e.g. `git reset HEAD~1`) followed by a new commit makes HEAD != head_before
    # true, but the new commit does NOT descend from head_before: a prior
    # cycle's already-committed commit was silently dropped from the branch.
    orphaned? =
      head_moved? and head_after != nil and
        not state.git_ancestor_fn.(state.cwd, head_before, head_after)

    # `committed?` is forward-only: a legitimate commit REQUIRES head_before
    # to still be an ancestor of the new HEAD. An orphaning move (HEAD moved,
    # but backward/sideways past head_before) must NOT be treated as
    # "committed" — else the post-commit-hiccup branches below would ship the
    # orphaned pitch, masking the failure.
    committed? = head_moved? and not orphaned?

    gate_clear? = state.gate_verdict_fn.(state.cwd) == "clear"

    cond do
      orphaned? ->
        # Deterministic failure — never transient, never retried. A blind
        # retry would re-run the same pitch and can re-orphan. HALT the queue
        # and leave the repo untouched; print the exact remediation.
        IO.puts(:stderr, orphan_remediation(head_before, head_after))
        emit_failure_diagnostics(jsonl, idx, state.total, slug)

        {:error,
         "queue: HALTED — #{slug} orphaned base #{head_before} (repo left untouched, see remediation above)"}

      committed? and gate_clear? and
          File.exists?(Path.join(state.shipped_dir, "#{slug}.md")) ->
        # committer-post-commit hiccup: agent already shipped the pitch
        # (moved ready/<slug>.md -> shipped/<slug>.md) before the non-zero
        # exit. Count it shipped, do not call ship/3 again (src is gone).
        IO.puts(:stderr, "[#{idx}/#{state.total}] #{slug} ... shipped")
        state = %{state | retry_count: 0, last_slug: nil}
        run_loop(state, shipped_count + 1)

      committed? and gate_clear? and File.exists?(Path.join(state.ready_dir, "#{slug}.md")) ->
        # committer-post-commit hiccup: commit landed, gate is clear, but the
        # pitch file is still sitting in ready/ (ship step never ran). Finish
        # the ship ourselves rather than halting the whole queue.
        ship(state.ready_dir, state.shipped_dir, slug)
        IO.puts(:stderr, "[#{idx}/#{state.total}] #{slug} ... shipped")
        state = %{state | retry_count: 0, last_slug: nil}
        run_loop(state, shipped_count + 1)

      retry_eligible?(state, slug, jsonl, committed?, gate_clear?) ->
        retry_count = if state.last_slug == slug, do: state.retry_count, else: 0
        attempt = retry_count + 1
        delay = pick_delay(state.retry_delays, attempt)
        IO.puts(:stderr, "[#{idx}/#{state.total}] #{slug} ... failed (retrying)")
        if delay > 0, do: state.sleep_fn.(delay)

        state = %{state | retry_count: attempt, last_slug: slug}
        run_slug(state, slug, shipped_count)

      true ->
        emit_failure_diagnostics(jsonl, idx, state.total, slug)
        {:error, "queue: #{slug} failed (deterministic or retries exhausted)"}
    end
  end

  # Copy-paste remediation for an orphaned-base cycle. `head_after` is the bad
  # commit HEAD landed on; rebasing everything from its parent onto
  # `head_before` replays the orphaned work back on top of the known-good base.
  @spec orphan_remediation(String.t(), String.t()) :: String.t()
  defp orphan_remediation(head_before, head_after) do
    "queue: HALTED — cycle orphaned base #{head_before}\n" <>
      "  HEAD (#{head_after}) does not descend from the cycle base.\n" <>
      "  Repo left untouched. To recover:\n" <>
      "    git rebase --onto #{head_before} #{head_after}^ HEAD\n" <>
      "  then re-run: claude-build --queue\n" <>
      "  (remaining pitches stay in ready/)"
  end

  # Fail-open jsonl parse (mirrors build-queue.sh:571-576): a malformed or
  # missing jsonl yields no result_text/session_id — never crashes the drain.
  defp emit_failure_diagnostics(jsonl, idx, total, slug) do
    case File.read(jsonl) do
      {:ok, content} ->
        records =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode/1)
          |> Enum.filter(&match?({:ok, %{"type" => "result"}}, &1))
          |> Enum.map(fn {:ok, map} -> map end)

        case List.last(records) do
          nil ->
            :ok

          last ->
            case Map.get(last, "result") do
              result when is_binary(result) and result != "" -> IO.puts(:stderr, result)
              _ -> :ok
            end

            case Map.get(last, "session_id") do
              session_id when is_binary(session_id) and session_id != "" ->
                IO.puts(:stderr, "session_id: " <> session_id)

              _ ->
                :ok
            end
        end

      {:error, _reason} ->
        :ok
    end

    IO.puts(:stderr, "[#{idx}/#{total}] #{slug} ... FAILED")
  end

  defp retry_eligible?(state, slug, jsonl, committed?, gate_clear?) do
    retry_count = if state.last_slug == slug, do: state.retry_count, else: 0

    (state.transient_fn.(jsonl) or (gate_clear? and not committed?)) and
      retry_count < state.max_retries
  end

  defp handle_timeout(state, slug, shipped_count, idx) do
    budget = state.pitch_budget_secs
    second_timeout? = MapSet.member?(state.timed_out_slugs, {:once, slug})

    outcome = if second_timeout?, do: "skipped", else: "stashed, retrying"

    IO.puts(
      :stderr,
      "[#{idx}/#{state.total}] #{slug} ... TIMED OUT (budget #{budget}s) — #{outcome}"
    )

    case state.git_stash_fn.(state.cwd, slug) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end

    if second_timeout? do
      # second timeout for this slug — mark skipped for the remainder of this run
      state = %{
        state
        | timed_out_slugs: MapSet.put(state.timed_out_slugs, slug),
          retry_count: 0,
          last_slug: nil
      }

      run_loop(state, shipped_count)
    else
      # first timeout — retry once
      state = %{
        state
        | timed_out_slugs: MapSet.put(state.timed_out_slugs, {:once, slug}),
          retry_count: 0,
          last_slug: nil
      }

      run_slug(state, slug, shipped_count)
    end
  end

  # ── Backoff ───────────────────────────────────────────────────────────────

  @spec pick_delay([non_neg_integer()], pos_integer()) :: non_neg_integer()
  defp pick_delay(delays, attempt) do
    idx = min(attempt, length(delays)) - 1
    Enum.at(delays, idx, List.last(delays) || 0)
  end

  # ── Env-toggle resolution ────────────────────────────────────────────────

  @doc "Resolves `CODEGEN_BUILD_QUEUE_MAX_RETRIES`, default #{@default_max_retries}."
  @spec max_retries_from_env() :: pos_integer()
  def max_retries_from_env do
    case System.get_env("CODEGEN_BUILD_QUEUE_MAX_RETRIES") do
      nil -> @default_max_retries
      str -> parse_pos_int(str, @default_max_retries)
    end
  end

  @doc "Resolves `CODEGEN_BUILD_QUEUE_RETRY_DELAYS` (space-separated seconds), default #{inspect(@default_retry_delays)}."
  @spec retry_delays_from_env() :: [non_neg_integer()]
  def retry_delays_from_env do
    case System.get_env("CODEGEN_BUILD_QUEUE_RETRY_DELAYS") do
      nil ->
        @default_retry_delays

      str ->
        parsed =
          str
          |> String.split(" ", trim: true)
          |> Enum.map(&Integer.parse/1)
          |> Enum.filter(&match?({_n, ""}, &1))
          |> Enum.map(&elem(&1, 0))

        if parsed == [], do: @default_retry_delays, else: parsed
    end
  end

  @doc "Resolves `CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS`, default #{@default_pitch_budget_secs}; 0/non-numeric → default."
  @spec pitch_budget_from_env() :: pos_integer()
  def pitch_budget_from_env do
    case System.get_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS") do
      nil ->
        @default_pitch_budget_secs

      str ->
        case Integer.parse(str) do
          {n, ""} when n > 0 -> n
          _ -> @default_pitch_budget_secs
        end
    end
  end

  defp parse_pos_int(str, default) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  @doc "Mention prefix for `harness`: `\"claude\"` -> `\"@\"`, `\"pi\"` -> `\"\"`."
  @spec mention_prefix(String.t()) :: String.t()
  def mention_prefix("claude"), do: "@"
  def mention_prefix("pi"), do: ""
  def mention_prefix(other), do: raise("LoopQueueDrain: unknown harness #{inspect(other)}")

  @doc false
  @spec pitch_arg_for(String.t(), String.t(), String.t()) :: String.t()
  def pitch_arg_for(slug, harness, cwd) do
    mention_prefix(harness) <> Path.join(cwd, "codegen/pitches/ready/#{slug}.md")
  end

  # ── Real spawn_fn: fresh codegen-build child, budget-bounded, JSONL capture ──

  @doc false
  @spec default_spawn_fn(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:exit_code, integer()} | :timeout
  def default_spawn_fn(slug, harness, stack, cwd, jsonl_path) do
    build_bin = Process.get(:__queue_drain_build_bin__, @codegen_build_bin)

    unless File.exists?(build_bin) do
      raise "LoopQueueDrain: codegen-build not found at #{build_bin}"
    end

    pitch_arg = pitch_arg_for(slug, harness, cwd)

    args = [
      "--harness=#{harness}",
      "--stack=#{stack}",
      "--cwd=#{cwd}",
      "--",
      pitch_arg
    ]

    env = [
      {~c"PATH", String.to_charlist(System.get_env("PATH") || "")},
      {~c"CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS", ~c"0"},
      {~c"CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS", ~c"0"},
      {~c"CLAUDE_STREAM_IDLE_TIMEOUT_MS", ~c"0"}
    ]

    budget_secs = pitch_budget_from_env()

    port =
      Port.open({:spawn_executable, build_bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:cd, cwd},
        {:env, env}
      ])

    collect_spawn_output(port, [], budget_secs * 1000, jsonl_path)
  end

  defp collect_spawn_output(port, acc, budget_ms, jsonl_path) do
    receive do
      {^port, {:data, chunk}} ->
        IO.binwrite(:stderr, chunk)
        collect_spawn_output(port, [chunk | acc], budget_ms, jsonl_path)

      {^port, {:exit_status, code}} ->
        File.write!(jsonl_path, IO.iodata_to_binary(Enum.reverse(acc)))
        {:exit_code, code}
    after
      budget_ms ->
        do_spawn_timeout(port, acc, jsonl_path)
    end
  end

  defp do_spawn_timeout(port, acc, jsonl_path) do
    kill_fn = Process.get(:__queue_drain_kill_fn__, &default_kill_tree/1)
    kill_fn.(port)

    File.write!(jsonl_path, IO.iodata_to_binary(Enum.reverse(acc)))

    try do
      Port.close(port)
    rescue
      ArgumentError -> :already_closed
    end

    :timeout
  end

  defp default_kill_tree(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true)
        System.cmd("pkill", ["-9", "-P", "#{os_pid}"], stderr_to_stdout: true)

      _ ->
        :ok
    end
  end

  @doc false
  @spec default_sleep_fn(non_neg_integer()) :: :ok
  def default_sleep_fn(secs) do
    Process.sleep(secs * 1000)
    :ok
  end

  @doc false
  @spec default_now_fn() :: integer()
  def default_now_fn, do: System.system_time(:second)

  # ── Real git_stash_fn: tracked-only, fail-open ──────────────────────────────

  @doc false
  @spec default_git_stash_fn(String.t(), String.t()) :: :ok | {:error, String.t()}
  def default_git_stash_fn(cwd, slug) do
    with {_out, 0} <-
           System.cmd("git", ["-C", cwd, "rev-parse", "--git-dir"], stderr_to_stdout: true),
         {status, 0} <-
           System.cmd("git", ["-C", cwd, "status", "--porcelain"], stderr_to_stdout: true) do
      tracked_dirty? =
        status
        |> String.split("\n", trim: true)
        |> Enum.any?(&(not String.starts_with?(&1, "??")))

      if tracked_dirty? do
        msg = "queue-timeout:#{slug}:#{default_now_fn()}"

        case System.cmd("git", ["-C", cwd, "stash", "push", "-u", "-m", msg],
               stderr_to_stdout: true
             ) do
          {_out, 0} -> :ok
          {out, _} -> {:error, "git stash failed: #{out}"}
        end
      else
        :ok
      end
    else
      {out, _code} -> {:error, "not a git repo or git status failed: #{out}"}
    end
  end

  # ── Real git_head_fn: fail-open (mirrors `git rev-parse HEAD 2>/dev/null || true`) ──

  @doc false
  @spec default_git_head_fn(String.t()) :: String.t() | nil
  def default_git_head_fn(cwd) do
    case System.cmd("git", ["-C", cwd, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {_out, _code} -> nil
    end
  end

  # ── Real git_ancestor_fn: `git merge-base --is-ancestor <a> <b>` ───────────
  # `--is-ancestor` exits 0 when `ancestor` IS an ancestor of `descendant`,
  # exits 1 when it is NOT (a normal, expected outcome — not an error), and
  # exits >1 / errors when the refs are invalid or cwd is not a git repo.
  # A genuine git-invocation error (invalid refs, non-git cwd — only
  # mocked/edge cases) fails OPEN to true so it never spuriously trips the
  # orphan-halt branch below; the exit-1 "not an ancestor" case is the one
  # this fn exists to detect and must return false.
  @doc false
  @spec default_git_ancestor_fn(String.t(), String.t(), String.t()) :: boolean()
  def default_git_ancestor_fn(cwd, ancestor, descendant) do
    case System.cmd("git", ["-C", cwd, "merge-base", "--is-ancestor", ancestor, descendant],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      {_out, 1} -> false
      {_out, _code} -> true
    end
  end

  # ── Real gate_verdict_fn: reads codegen/gate-pending/gate-result.json ──────

  @doc false
  @spec default_gate_verdict_fn(String.t()) :: String.t()
  def default_gate_verdict_fn(cwd) do
    path = Path.join([cwd, "codegen", "gate-pending", "gate-result.json"])

    with {:ok, content} <- File.read(path),
         {:ok, %{"verdict" => verdict}} <- Jason.decode(content),
         true <- is_binary(verdict) do
      verdict
    else
      _ -> ""
    end
  end

  # ── Real discover_session_log_fn: newest *_<slug>_cycle.jsonl at/after spawn ──
  # Mirrors legacy `latest_session_log` (build-queue.sh:254-268) + poll loop
  # (build-queue.sh:426, 30 iterations x sleep 1). Bounded retry, fail-open
  # (no hit after the window -> nil; echo_paths/4 ignores the nil, the caller
  # already has the same artifact path via `jsonl`).

  @discover_max_polls 30

  @doc false
  @spec default_discover_session_log(String.t(), String.t(), String.t(), pos_integer()) ::
          String.t() | nil
  def default_discover_session_log(cwd, slug, spawn_stamp, max_polls \\ @discover_max_polls) do
    poll_discover_session_log(cwd, slug, spawn_stamp, max_polls)
  end

  defp poll_discover_session_log(cwd, slug, spawn_stamp, tries_left) do
    case newest_session_log(cwd, slug, spawn_stamp) do
      nil when tries_left > 0 ->
        Process.sleep(1000)
        poll_discover_session_log(cwd, slug, spawn_stamp, tries_left - 1)

      result ->
        result
    end
  end

  defp newest_session_log(cwd, slug, spawn_stamp) do
    pattern = Path.join([cwd, "codegen", "logging", "*_#{slug}_cycle.jsonl"])

    pattern
    |> Path.wildcard()
    |> Enum.map(fn path -> {session_log_stamp(path, slug), path} end)
    |> Enum.filter(fn {stamp, _path} -> stamp != nil and stamp >= spawn_stamp end)
    |> Enum.max_by(fn {stamp, _path} -> stamp end, fn -> {nil, nil} end)
    |> elem(1)
  end

  defp session_log_stamp(path, slug) do
    suffix = "_#{slug}_cycle.jsonl"
    base = Path.basename(path)

    if String.ends_with?(base, suffix) do
      String.replace_suffix(base, suffix, "")
    else
      nil
    end
  end
end
