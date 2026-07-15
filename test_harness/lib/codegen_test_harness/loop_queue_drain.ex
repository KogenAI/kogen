defmodule CodegenTestHarness.LoopQueueDrain do
  @moduledoc """
  Multi-pitch drain over `codegen/pitches/ready/`: reproduces
  `harnesses/shared/build-queue.sh`'s process contract on top of the shipped
  Elixir loop. Spawns one fresh `codegen-build` child per ordered pitch
  (zero cross-pitch context accumulation), transient-retries with backoff,
  enforces a per-pitch wall-clock budget/watchdog, stashes a dirty tree on
  timeout (restoring it before the retry attempt — see `:git_stash_restore_fn`),
  and moves `ready/<slug>.md` to `shipped/<slug>.md` on a VERIFIED ship.

  Wires `CodegenTestHarness.LoopQueue.ordered_slugs/1` (topo-order,
  raise-on-cycle) and `LoopQueue.transient?/1` (JSONL classify) live — both
  were previously unreachable from any runtime caller.

  Old `build-queue.sh` `build-queue.json` position-manifest concerns are
  superseded by a verified-commit check, NOT the child's bare exit code. A
  child exit code of 0 is NECESSARY but not SUFFICIENT proof of a real ship
  — see `handle_exit_zero/7`: it additionally requires `committed?` (HEAD
  moved forward, non-orphaning, since the pre-spawn `head_before` read) AND
  a FRESH `gate_clear?` (verdict `"clear"` AND its recorded `base_sha` is a
  prefix of `head_before` AND the gate record's mtime is at/after this
  attempt's spawn timestamp — never a stale verdict from an earlier cycle)
  before shipping. The gate ALWAYS runs BEFORE the committer (loop role
  order: planner -> developer -> gate -> reviewer -> curator -> committer),
  so the recorded `base_sha` can only ever prefix `head_before` — never the
  post-commit `head_after`. The mtime leg is what rejects a stale clear
  verdict left on disk by an EARLIER cycle: `head_before` alone cannot
  distinguish "this cycle's gate" from "an earlier cycle's gate" when a
  prior attempt failed without committing (same base, stale record). An
  exit-0 without a verified commit under a fresh clear gate (a "false-0")
  is treated as a deterministic failure: the dirty tree is stashed and the
  pitch is skipped-and-continued, same as a genuine nonzero exit.
  `is_gate_green`/committed-but-nonzero recovery (legacy `build-queue.sh`
  lines 529, 546-551, 554) IS ported — see `git_head_fn`/`gate_verdict_fn`
  below: a committer-post-commit hiccup (child exits non-zero after HEAD
  already moved and the gate verdict is `"clear"` AND fresh) ships or
  counts the pitch as shipped instead of halting the whole queue.

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

  A deterministic child failure (or a pitch that burns through all of its
  own transient retries without succeeding) SKIPS-AND-CONTINUES rather than
  aborting the whole drain: the pitch stays physically in `ready_dir`, its
  dirty tree is stashed under `queue-fail:<slug>:<ts>` (fail-open, parked
  for operator forensics — never auto-popped; `:git_stash_restore_fn` only
  matches the `queue-timeout:` prefix), and the slug is added to a
  `failed_slugs` set rejected on every subsequent scan. This is guarded by a
  consecutive-failure circuit breaker (`:max_consecutive_fails`, default 3,
  env `CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS`): any ship resets the
  streak to 0; hitting the threshold HALTs the drain with `{:error, reason}`
  under the theory that a systemically-broken environment (not an isolated
  bad pitch) is failing every build. Isolated failures below the threshold
  are tolerated — `drain/1` still returns `{:ok, shipped_count}` and prints
  a FAILED bucket (parallel to the SKIPPED unmet-dep bucket) naming every
  skipped slug.

  A THIRD, distinct child outcome exists alongside "shipped" and
  "deterministic failure": an INFRA ABORT (`mix codegen.loop` exiting with
  its dedicated code for `CodegenTestHarness.InfraAbort` — a fault no
  developer edit could fix, e.g. a gate poisoned by pre-existing DB state,
  or a scan no diff could ever satisfy). Unlike a deterministic failure,
  this is NEVER stashed and NEVER skipped-and-continued: an infra fault
  poisons every pitch behind it in the queue (the incident motivating this:
  one poisoned DB killed three consecutive pitches, each blamed on its own
  developer and reworked before failing anyway), so it HALTS the whole
  drain outright with `{:error, reason}`, leaving the in-flight pitch
  untouched in `ready_dir` — nothing about THAT pitch's diff was wrong. See
  `handle_infra_abort/4`.
  """

  alias CodegenTestHarness.{BuildLock, LoopQueue}

  @type drain_opts :: keyword()

  @default_max_retries 3
  @default_retry_delays [30, 120, 300]
  @default_max_consecutive_fails 3
  # Retention window for `codegen/logging/*_build.log` console captures —
  # ephemeral gitignored build-forensics; never applied to `*_cycle.jsonl`
  # (the canonical, durable per-role session logs).
  @build_log_retention_secs 7 * 24 * 3600
  @default_pitch_budget_secs 7200
  # `mix codegen.loop`'s distinct exit code for `CodegenTestHarness.InfraAbort`
  # (see `Mix.Tasks.Codegen.Loop` `@infra_abort_exit_code`) — a fault no
  # developer edit could fix.
  @infra_abort_exit_code 3

  @codegen_build_bin Path.expand("../../../codegen-build", __DIR__)

  # `:persistent_term` key holding the OS pid of the currently in-flight
  # spawned child (set right after `Port.open` in `default_spawn_fn/5`,
  # cleared once the port concludes normally). This is the invariant this
  # module exists to close: "a build's process tree dies with the run that
  # spawned it" — an exit via crash/raise/normal-return must reap the SAME
  # subtree the timeout path already reaps (`default_kill_tree/1`), not only
  # a budget timeout. `drain/1`'s `after` block calls `reap_in_flight_tree/0`
  # unconditionally so every exit path is covered, not only the explicit
  # timeout branch.
  @in_flight_os_pid_key {__MODULE__, :in_flight_os_pid}

  @doc """
  Drains `<cwd>/codegen/pitches/ready/` for `opts[:harness]`/`opts[:stack]`/
  `opts[:cwd]`. Returns `{:ok, shipped_count}` once `ready/` empties (either
  on the first scan — nothing to do — or after shipping every pitch that
  isn't left behind by a deterministic failure/skip). Isolated deterministic
  failures (below the `:max_consecutive_fails` circuit-breaker threshold)
  are TOLERATED — the pitch is skipped-and-continued (see moduledoc), not a
  drain failure. Returns `{:error, reason}` only on a circuit-breaker trip
  (too many consecutive deterministic failures), an orphaned base, or lock
  contention.

  The printed `[n/N]` progress index counts CONCLUDED pitches (shipped OR
  terminally failed/skipped) — never a retry of the same slug in place. This
  is a DIFFERENT counter from the returned `shipped_count`: a queue where
  every pitch fails still advances `[1/N]`, `[2/N]`, ... `[N/N]` on stderr
  while `drain/1` returns `{:ok, 0}`.

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
    * `:pitch_budget_secs` — default 7200 (env `CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS`)
    * `:max_consecutive_fails` — default 3 (env
      `CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS`); consecutive deterministic
      pitch failures (no ship in between) at which the drain HALTs instead of
      skipping-and-continuing (circuit breaker — see moduledoc)
    * `:spawn_fn` — `(slug, harness, stack, cwd, jsonl_path -> {:exit_code, integer} | :timeout)`
    * `:sleep_fn` — `(secs -> :ok)`
    * `:git_stash_fn` — `(cwd, slug, reason -> :ok | {:error, reason})` where
      `reason` is `"timeout"` or `"fail"`; label is `queue-<reason>:<slug>:<ts>`.
      `"fail"`-reason stashes are NEVER auto-popped — `:git_stash_restore_fn`
      only matches the `queue-timeout:` prefix, so they are parked for
      operator forensics.
    * `:git_stash_restore_fn` — `(cwd, slug -> :ok | {:error, reason})`, pops a
      prior `queue-timeout:<slug>:` stash (if any) before a retry attempt for
      `slug`. No matching stash -> `:ok` (no-op). A pop conflict fails loud
      with `{:error, reason}`, HALTing the whole drain — git retains the
      stash on a conflicting pop, so the error names a recoverable ref.
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
    * `:gate_base_sha_fn` — `(cwd -> String.t())`, default reads
      `codegen/gate-pending/gate-result.json` `.base_sha` (SHORT sha); `""`
      when absent. Compared against `head_before` (FULL sha, the base the
      gate actually ran against — the loop gates BEFORE the committer) via
      `String.starts_with?/2`, never a bare equality (which would always
      fail short-vs-full), and never `head_after` — no gate record can ever
      carry a post-commit sha.
    * `:gate_mtime_fn` — `(cwd -> integer unix secs)`, default reads
      `codegen/gate-pending/gate-result.json`'s mtime via
      `File.stat(path, time: :posix)`; `0` when absent/unstattable
      (fail-closed sentinel — older than any real spawn `ts`). Paired with
      `:gate_base_sha_fn` in `gate_fresh?/3`: rejects a stale "clear"
      verdict left on disk by an EARLIER cycle that shares the same
      `head_before` (two consecutive non-committing attempts have an
      identical base, so the sha leg alone cannot tell them apart).
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

    pid_alive_fn = Keyword.get(opts, :pid_alive_fn, &BuildLock.default_pid_alive?/1)
    orphan_scan_fn = Keyword.get(opts, :orphan_scan_fn, &default_build_orphan_scan/1)

    with :ok <- refuse_if_build_orphan(cwd, orphan_scan_fn),
         :ok <- BuildLock.acquire(lock_path, "queue", pid_alive_fn) do
      try do
        # Move 3 wiring: `default_spawn_fn/5` updates this SAME lock
        # file's `tree=<os_pid>` token right after each per-pitch child
        # starts (see `:__queue_drain_lock_path__` read there), so a
        # second builder's `BuildLock.acquire/4` can discover the
        # CURRENTLY in-flight child even though the drain acquired the
        # lock once, up front, before any child existed.
        Process.put(:__queue_drain_lock_path__, lock_path)

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
          lock_path: lock_path,
          max_retries: Keyword.get(opts, :max_retries, max_retries_from_env()),
          retry_delays: Keyword.get(opts, :retry_delays, retry_delays_from_env()),
          pitch_budget_secs: Keyword.get(opts, :pitch_budget_secs, pitch_budget_from_env()),
          max_consecutive_fails:
            Keyword.get(opts, :max_consecutive_fails, max_consecutive_fails_from_env()),
          spawn_fn: Keyword.get(opts, :spawn_fn, &default_spawn_fn/5),
          sleep_fn: Keyword.get(opts, :sleep_fn, &default_sleep_fn/1),
          git_stash_fn: Keyword.get(opts, :git_stash_fn, &default_git_stash_fn/3),
          git_stash_restore_fn:
            Keyword.get(opts, :git_stash_restore_fn, &default_git_stash_restore_fn/2),
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
          gate_base_sha_fn: Keyword.get(opts, :gate_base_sha_fn, &default_gate_base_sha_fn/1),
          gate_mtime_fn: Keyword.get(opts, :gate_mtime_fn, &default_gate_mtime_fn/1),
          discover_session_log_fn:
            Keyword.get(opts, :discover_session_log_fn, &default_discover_session_log/3),
          timed_out_slugs: MapSet.new(),
          failed_slugs: MapSet.new(),
          consecutive_fails: 0,
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

        run_loop(state, 0, 0)
      after
        # Exit-path reap (Move 1): a crash/raise propagating out of
        # `run_loop` (or its own normal `{:ok, _}` return) must not leave an
        # in-flight spawned child's tree running. `reap_in_flight_tree/0` is
        # a no-op when the port already concluded normally (the key is
        # cleared in `collect_spawn_output/4`'s exit_status branch) —
        # this only fires when something is genuinely still in flight.
        reap_in_flight_tree()
        Process.delete(:__queue_drain_lock_path__)
        BuildLock.release(lock_path)
      end
    else
      {:error, reason} ->
        {:error, "queue: #{reason}"}
    end
  end

  # Move 4: startup preflight — scans for a live `codegen-build` process
  # already bound to THIS cwd, left running by a prior drain whose BEAM
  # died (crash, `kill -9`, OOM) without releasing its lock file at all —
  # the case Move 3 cannot see, because Move 3 only fires when the LOCK
  # FILE still names a dead pid; a lock file deleted by hand (the
  # operator's own `rm -f queue.lock` recovery step) leaves no trace for
  # Move 3 to compare against. Reuses the SAME `ps_fn` seam the reap
  # already uses (`__queue_drain_ps_fn__`) — one process-inspection
  # mechanism, not a second one. Never auto-kills: refuses loud, naming the
  # pids and the reap command, mirroring `OrchestrationLoop.refuse_if_orphan/2`'s
  # contract for the solo path.
  @spec refuse_if_build_orphan(String.t(), (String.t() -> [String.t()])) ::
          :ok | {:error, String.t()}
  defp refuse_if_build_orphan(cwd, orphan_scan_fn) do
    case orphan_scan_fn.(cwd) do
      [] ->
        :ok

      pids when is_list(pids) ->
        {:error,
         "orphan codegen-build process(es) already running for this cwd: " <>
           Enum.join(pids, ", ") <>
           " — refusing to start a second. Inspect with `ps -p " <>
           Enum.join(pids, ",") <>
           " -o pid,etime,command`, then reap with `kill -9 " <>
           Enum.join(pids, " ") <> "` if confirmed stale."}
    end
  end

  # Real orphan_scan_fn for Move 4: `pgrep -f` matching `codegen-build
  # .*--cwd=<cwd>`, excluding this process's own OS pid. Degrades to `[]`
  # (lock-only enforcement) when `pgrep` itself is unavailable — mirrors
  # `OrchestrationLoop.default_orphan_scan/1`'s identical fail-open
  # contract for the solo path.
  @doc false
  @spec default_build_orphan_scan(String.t()) :: [String.t()]
  def default_build_orphan_scan(cwd) do
    pattern = "codegen-build .*--cwd=#{Regex.escape(cwd)}"

    case System.cmd("pgrep", ["-f", pattern], stderr_to_stdout: true) do
      {output, 0} ->
        self_pid = System.pid()

        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == self_pid))

      # fail-loud-exempt: pgrep exit 1 means "no matches" — an empty
      # result, not an error (mirrors OrchestrationLoop.default_orphan_scan/1).
      {_output, 1} ->
        []

      # fail-loud-exempt: `pgrep` missing from PATH or another exec error —
      # this preflight is a secondary guard on top of the per-cwd lock
      # (primary). Degrading to lock-only enforcement here is a justified,
      # commented fail-open, not a silent swallow: logged loud on stderr.
      {output, _other_code} ->
        IO.puts(:stderr, "queue: orphan scan skipped — pgrep unavailable: #{output}")
        []
    end
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

  # ── Main loop ─────────────────────────────────────────────────────────────

  defp run_loop(state, shipped_count, concluded_count) do
    ordered = state.ordered_fn.(state.ready_dir)
    blocked = state.blocked_fn.()

    state = print_new_blocked(state, blocked)

    remaining =
      Enum.reject(ordered, fn slug ->
        MapSet.member?(state.timed_out_slugs, slug) or
          MapSet.member?(state.failed_slugs, slug) or Map.has_key?(blocked, slug)
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

        if MapSet.size(state.failed_slugs) > 0 do
          IO.puts(
            :stderr,
            "queue: FAILED bucket: " <> Enum.join(state.failed_slugs, ", ")
          )
        end

        {:ok, shipped_count}

      [slug | _] ->
        run_slug(state, slug, shipped_count, concluded_count)
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

  defp run_slug(state, slug, shipped_count, concluded_count) do
    case state.git_stash_restore_fn.(state.cwd, slug) do
      :ok -> do_run_slug(state, slug, shipped_count, concluded_count)
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_run_slug(state, slug, shipped_count, concluded_count) do
    idx = concluded_count + 1
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
        handle_exit_zero(state, slug, jsonl, head_before, shipped_count, concluded_count, idx, ts)

      {:exit_code, @infra_abort_exit_code} ->
        handle_infra_abort(jsonl, idx, state.total, slug)

      {:exit_code, _n} ->
        handle_nonzero_exit(state, slug, jsonl, head_before, shipped_count, concluded_count, idx, ts)

      :timeout ->
        handle_timeout(state, slug, shipped_count, concluded_count, idx)
    end
  end

  # An infra fault poisons every pitch behind it (the 20260713 incident: one
  # poisoned DB killed three consecutive pitches), so this HALTS the drain
  # outright — no stash, no skip-and-continue, no pitch-failure verdict.
  # The pitch that was mid-flight stays untouched in `ready_dir` (nothing
  # about IT was wrong).
  defp handle_infra_abort(jsonl, idx, total, slug) do
    emit_failure_diagnostics(jsonl, idx, total, slug)

    {:error,
     "queue: HALTED — #{slug} hit an infra abort (a fault no developer edit could fix). " <>
       "Fix the box, then re-run: claude-build --queue (pitch remains untouched in ready/)"}
  end

  # A gate record is trustworthy only if a real gate wrote it, THIS cycle,
  # against THIS cycle's base. The loop gates BEFORE the committer
  # (orchestration_loop.ex role order: planner -> developer -> gate ->
  # reviewer -> curator -> committer), so the recorded short `base_sha` can
  # only ever prefix `head_before` — never the post-commit `head_after`. The
  # mtime leg (gate record written at/after this child's spawn `ts`) is what
  # rejects a stale "clear" verdict left on disk by an EARLIER cycle:
  # `head_before` alone cannot distinguish "this cycle's gate" from "a prior
  # cycle's gate" when an earlier attempt failed without committing (same
  # base, stale record).
  @spec gate_fresh?(map(), String.t() | nil, integer()) :: boolean()
  defp gate_fresh?(state, head_before, ts) do
    base_sha = state.gate_base_sha_fn.(state.cwd)

    base_sha != "" and is_binary(head_before) and head_before != "" and
      String.starts_with?(head_before, base_sha) and
      state.gate_mtime_fn.(state.cwd) >= ts
  end

  # A child exit code of 0 is NOT sufficient proof the cycle actually shipped
  # a commit under a clear gate — a false-0 (the at-source defect is tracked
  # separately: draft loop-exits-zero-despite-failed-cycle) would otherwise
  # sail straight to "shipped" with HEAD unmoved and a dirty tree. Symmetric
  # with handle_nonzero_exit/7: verify `committed?` (HEAD moved forward,
  # non-orphaning) AND a FRESH `gate_clear?` (verdict "clear" AND
  # `gate_fresh?/3` — its recorded short base_sha is a prefix of
  # `head_before`, the base the gate actually ran against, AND its mtime is
  # at/after this attempt's spawn `ts` — never a stale verdict from an
  # earlier cycle) before shipping. Anything short of that is treated as a
  # failed cycle: stash the dirty tree and fall through the same
  # skip-and-continue / circuit-breaker path as a deterministic nonzero
  # failure.
  defp handle_exit_zero(state, slug, jsonl, head_before, shipped_count, concluded_count, idx, ts) do
    known_base? = head_before != nil and head_before != ""
    head_after = if known_base?, do: state.git_head_fn.(state.cwd), else: nil
    head_moved? = known_base? and head_after != head_before

    orphaned? =
      head_moved? and head_after != nil and
        not state.git_ancestor_fn.(state.cwd, head_before, head_after)

    committed? = head_moved? and not orphaned?

    gate_clear? =
      state.gate_verdict_fn.(state.cwd) == "clear" and gate_fresh?(state, head_before, ts)

    cond do
      orphaned? ->
        IO.puts(:stderr, orphan_remediation(head_before, head_after))
        emit_failure_diagnostics(jsonl, idx, state.total, slug)

        {:error,
         "queue: HALTED — #{slug} orphaned base #{head_before} (repo left untouched, see remediation above)"}

      committed? and gate_clear? ->
        ship(state.ready_dir, state.shipped_dir, slug)
        IO.puts(:stderr, "[#{idx}/#{state.total}] #{slug} ... shipped")
        state = %{state | retry_count: 0, last_slug: nil, consecutive_fails: 0}
        run_loop(state, shipped_count + 1, concluded_count + 1)

      true ->
        # False exit-0: no verified commit under a fresh clear gate. Treat as
        # a deterministic failure — stash whatever dirty tree is left (never
        # auto-popped, `queue-fail:` prefix, operator forensics), skip and
        # continue subject to the same consecutive-failure circuit breaker.
        IO.puts(
          :stderr,
          "[#{idx}/#{state.total}] #{slug} ... exit 0 but no verified commit under a fresh clear gate — treating as FAILED"
        )

        emit_failure_diagnostics(jsonl, idx, state.total, slug)

        case state.git_stash_fn.(state.cwd, slug, "fail") do
          :ok -> :ok
          {:error, _reason} -> :ok
        end

        failed_slugs = MapSet.put(state.failed_slugs, slug)
        consecutive_fails = state.consecutive_fails + 1

        if consecutive_fails >= state.max_consecutive_fails do
          {:error,
           "queue: HALTED — #{consecutive_fails} consecutive deterministic failures " <>
             "(#{Enum.join(failed_slugs, ", ")}), environment likely broken — fix env, re-run; " <>
             "failed pitches remain in ready/, work recoverable from queue-fail: stashes"}
        else
          state = %{
            state
            | failed_slugs: failed_slugs,
              consecutive_fails: consecutive_fails,
              retry_count: 0,
              last_slug: nil
          }

          run_loop(state, shipped_count, concluded_count + 1)
        end
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

  defp handle_nonzero_exit(state, slug, jsonl, head_before, shipped_count, concluded_count, idx, ts) do
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

    # A stale "clear" record from an earlier cycle must not ship a real
    # commit twice-removed from the gate that actually verified it — apply
    # the same freshness predicate the exit-0 path uses.
    gate_clear? =
      state.gate_verdict_fn.(state.cwd) == "clear" and gate_fresh?(state, head_before, ts)

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
        state = %{state | retry_count: 0, last_slug: nil, consecutive_fails: 0}
        run_loop(state, shipped_count + 1, concluded_count + 1)

      committed? and gate_clear? and File.exists?(Path.join(state.ready_dir, "#{slug}.md")) ->
        # committer-post-commit hiccup: commit landed, gate is clear, but the
        # pitch file is still sitting in ready/ (ship step never ran). Finish
        # the ship ourselves rather than halting the whole queue.
        ship(state.ready_dir, state.shipped_dir, slug)
        IO.puts(:stderr, "[#{idx}/#{state.total}] #{slug} ... shipped")
        state = %{state | retry_count: 0, last_slug: nil, consecutive_fails: 0}
        run_loop(state, shipped_count + 1, concluded_count + 1)

      retry_eligible?(state, slug, jsonl, committed?, gate_clear?) ->
        retry_count = if state.last_slug == slug, do: state.retry_count, else: 0
        attempt = retry_count + 1
        delay = pick_delay(state.retry_delays, attempt)
        IO.puts(:stderr, "[#{idx}/#{state.total}] #{slug} ... failed (retrying)")
        if delay > 0, do: state.sleep_fn.(delay)

        state = %{state | retry_count: attempt, last_slug: slug}
        run_slug(state, slug, shipped_count, concluded_count)

      true ->
        emit_failure_diagnostics(jsonl, idx, state.total, slug)

        case state.git_stash_fn.(state.cwd, slug, "fail") do
          :ok -> :ok
          {:error, _reason} -> :ok
        end

        failed_slugs = MapSet.put(state.failed_slugs, slug)
        consecutive_fails = state.consecutive_fails + 1

        if consecutive_fails >= state.max_consecutive_fails do
          {:error,
           "queue: HALTED — #{consecutive_fails} consecutive deterministic failures " <>
             "(#{Enum.join(failed_slugs, ", ")}), environment likely broken — fix env, re-run; " <>
             "failed pitches remain in ready/, work recoverable from queue-fail: stashes"}
        else
          state = %{
            state
            | failed_slugs: failed_slugs,
              consecutive_fails: consecutive_fails,
              retry_count: 0,
              last_slug: nil
          }

          run_loop(state, shipped_count, concluded_count + 1)
        end
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

  defp handle_timeout(state, slug, shipped_count, concluded_count, idx) do
    budget = state.pitch_budget_secs
    second_timeout? = MapSet.member?(state.timed_out_slugs, {:once, slug})

    outcome = if second_timeout?, do: "skipped", else: "stashed, retrying"

    IO.puts(
      :stderr,
      "[#{idx}/#{state.total}] #{slug} ... TIMED OUT (budget #{budget}s) — #{outcome}"
    )

    case state.git_stash_fn.(state.cwd, slug, "timeout") do
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

      run_loop(state, shipped_count, concluded_count + 1)
    else
      # first timeout — retry once
      state = %{
        state
        | timed_out_slugs: MapSet.put(state.timed_out_slugs, {:once, slug}),
          retry_count: 0,
          last_slug: nil
      }

      run_slug(state, slug, shipped_count, concluded_count)
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

  @doc "Resolves `CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS`, default #{@default_max_consecutive_fails}."
  @spec max_consecutive_fails_from_env() :: pos_integer()
  def max_consecutive_fails_from_env do
    case System.get_env("CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS") do
      nil -> @default_max_consecutive_fails
      str -> parse_pos_int(str, @default_max_consecutive_fails)
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
      {~c"CLAUDE_STREAM_IDLE_TIMEOUT_MS", ~c"0"},
      # The drain already holds the outer per-cwd lock (same physical
      # queue.lock file — see acquire above); this per-pitch codegen-build
      # child's OrchestrationLoop.run/1 must NOT re-acquire it, or every
      # queued pitch would immediately refuse against its own parent's lock.
      {~c"CODEGEN_BUILD_LOCK_HELD", ~c"1"}
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

    # Record the in-flight os_pid (Move 1) BEFORE blocking on the port's
    # output/exit — this is what lets `reap_in_flight_tree/0` (called from
    # `drain/1`'s `after`) find and reap this child's subtree on any exit
    # path (crash, raise, normal `{:ok, _}` return), not only the explicit
    # timeout branch below. Cleared in `collect_spawn_output/4`'s
    # exit_status branch once the port concludes normally.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        :persistent_term.put(@in_flight_os_pid_key, os_pid)

        # Move 3: keep the lock file's `tree=<os_pid>` token current as each
        # new per-pitch child starts — best-effort, no-op when this drain's
        # lock_path was never recorded (e.g. a test calling
        # default_spawn_fn/5 directly, outside drain/1).
        case Process.get(:__queue_drain_lock_path__) do
          nil -> :ok
          lock_path -> BuildLock.update_tree_pid(lock_path, os_pid)
        end

      # fail-loud-exempt: Port.info/2 returning nil immediately after
      # Port.open/2 would mean the port already closed before this line ran
      # — an extreme race, not a normal outcome. Nothing to track yet; the
      # exit_status branch below still fires normally.
      nil ->
        :ok
    end

    collect_spawn_output(port, [], budget_secs * 1000, jsonl_path)
  end

  defp collect_spawn_output(port, acc, budget_ms, jsonl_path) do
    receive do
      {^port, {:data, chunk}} ->
        IO.binwrite(:stderr, chunk)
        collect_spawn_output(port, [chunk | acc], budget_ms, jsonl_path)

      {^port, {:exit_status, code}} ->
        :persistent_term.erase(@in_flight_os_pid_key)
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
    :persistent_term.erase(@in_flight_os_pid_key)

    File.write!(jsonl_path, IO.iodata_to_binary(Enum.reverse(acc)))

    try do
      Port.close(port)
    rescue
      ArgumentError -> :already_closed
    end

    :timeout
  end

  # Move 1 entry point: reaps whatever subtree is CURRENTLY recorded as
  # in-flight (if any) via the SAME ppid descendant-walk the timeout path
  # uses (`reap_os_pid_subtree/1`, which `default_kill_tree/1` now
  # delegates to). A no-op — :persistent_term.get/2 returns the default and
  # nothing is reaped — when no child is in flight (the common case: the
  # drain concluded normally and the key was already erased).
  @doc false
  @spec reap_in_flight_tree() :: :ok
  def reap_in_flight_tree do
    case :persistent_term.get(@in_flight_os_pid_key, nil) do
      nil ->
        :ok

      os_pid ->
        ps_fn = Process.get(:__queue_drain_ps_fn__, &default_ps_lister/0)
        reap_descendant_subtree(os_pid, ps_fn, 2)
        :persistent_term.erase(@in_flight_os_pid_key)
        :ok
    end
  end

  # Reaps the FULL transitive descendant subtree of the timed-out port's OS
  # pid via a ppid descendant-walk — NOT a process-group kill. The
  # Port.open-spawned child is never a session/group leader (no `setsid` on
  # macOS; `codegen-build` does not re-session either), so its pgid equals
  # the drain beam's own pgid — `kill -9 -<os_pid>` targets a pgid that does
  # not exist and reaps nothing. `pkill -9 -P <os_pid>` only reaps DIRECT
  # children, missing grandchildren (`mix codegen.loop` -> `claude` CLI ->
  # any subprocess it spawns, e.g. `caffeinate`). ppid links survive
  # re-sessioning (a re-sessioned child keeps its parent pid), so the walk
  # reaps the full subtree regardless of intermediate session boundaries.
  #
  # Post-reap: re-enumerate; if survivors remain, retry the walk ONCE, then
  # emit a LOUD stderr line naming survivor pids (never silently return as
  # if clean — a missed reap must be visible, not masked).
  defp default_kill_tree(port) do
    ps_fn = Process.get(:__queue_drain_ps_fn__, &default_ps_lister/0)

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        reap_descendant_subtree(os_pid, ps_fn, 2)

      # fail-loud-exempt: Port.info/2 returns nil when the port is already
      # closed (process exited between the timeout firing and this call) —
      # a legitimate race, not an unexpected condition. Nothing to reap.
      nil ->
        :ok
    end
  end

  # Solo-path (Move 2, `mix codegen.loop`) entry point: unlike the queue
  # drain, the solo path never `Port.open`s a tracked child — its heavy
  # subprocess (`codegen-call` -> `claude`) runs via synchronous
  # `System.cmd/3`, which does not expose an os_pid this module can record.
  # Reaps the CURRENT process's own OS-level descendant subtree (via the
  # same ppid walk `reap_descendant_subtree/3` performs) WITHOUT killing the
  # root itself — the root here is this BEAM, whose own halt is the
  # caller's job (`BuildSignalHandler`), not this fn's.
  @doc false
  @spec reap_own_descendants() :: :ok
  def reap_own_descendants do
    ps_fn = Process.get(:__queue_drain_ps_fn__, &default_ps_lister/0)
    self_os_pid = System.pid() |> String.to_integer()
    table = ps_fn.()
    descendants = collect_descendants(self_os_pid, table)

    Enum.each(descendants, fn pid ->
      System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    survivors = Enum.filter(descendants, &BuildLock.default_pid_alive?(Integer.to_string(&1)))

    unless survivors == [] do
      IO.puts(
        :stderr,
        "queue: reap_own_descendants: survivor pid(s): " <>
          Enum.map_join(survivors, ", ", &Integer.to_string/1)
      )
    end

    :ok
  end

  defp reap_descendant_subtree(_os_pid, _ps_fn, 0), do: :ok

  defp reap_descendant_subtree(os_pid, ps_fn, attempts_left) do
    table = ps_fn.()
    descendants = collect_descendants(os_pid, table)
    targets = [os_pid | descendants]

    Enum.each(targets, fn pid ->
      System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    survivors = Enum.filter(targets, &BuildLock.default_pid_alive?(Integer.to_string(&1)))

    case {survivors, attempts_left} do
      {[], _} ->
        :ok

      {_survivors, left} when left > 1 ->
        reap_descendant_subtree(os_pid, ps_fn, left - 1)

      {survivors, _} ->
        IO.puts(
          :stderr,
          "queue: kill_tree: survivor pid(s) after reap retry: " <>
            Enum.map_join(survivors, ", ", &Integer.to_string/1)
        )

        :ok
    end
  end

  # Collects every transitive descendant of `os_pid` from `table` (a list of
  # `{pid, ppid}` tuples). Builds a ppid -> [pid] adjacency map, then walks
  # it breadth-first from `os_pid`. Never includes `os_pid` itself.
  defp collect_descendants(os_pid, table) do
    children_by_ppid =
      Enum.reduce(table, %{}, fn {pid, ppid}, acc ->
        Map.update(acc, ppid, [pid], &[pid | &1])
      end)

    walk_descendants([os_pid], children_by_ppid, [])
  end

  defp walk_descendants([], _children_by_ppid, acc), do: acc

  defp walk_descendants([pid | rest], children_by_ppid, acc) do
    children = Map.get(children_by_ppid, pid, [])
    walk_descendants(children ++ rest, children_by_ppid, children ++ acc)
  end

  # Real ps_fn: enumerates the full system process table as `{pid, ppid}`
  # tuples via `ps -A -o pid=,ppid=` — POSIX, works unmodified on both macOS
  # and Linux.
  @doc false
  @spec default_ps_lister() :: [{pos_integer(), pos_integer()}]
  def default_ps_lister do
    case System.cmd("ps", ["-A", "-o", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_ps_line/1)

      # fail-loud-exempt: a failing `ps` invocation (missing binary, sandboxed
      # environment) must not crash the timeout-handling path — the caller
      # already reduces to a best-effort reap; an empty table degrades to
      # "no descendants found" (only the top-level os_pid is still killed).
      {_output, _nonzero} ->
        []
    end
  end

  defp parse_ps_line(line) do
    case String.split(String.trim(line)) do
      [pid_str, ppid_str] ->
        case {Integer.parse(pid_str), Integer.parse(ppid_str)} do
          {{pid, ""}, {ppid, ""}} -> [{pid, ppid}]
          # fail-loud-exempt: a non-numeric ps field (rare platform quirk,
          # e.g. locale-formatted output) is skipped for THIS line only —
          # the walk degrades gracefully rather than crashing the whole
          # timeout-handling path on one malformed row.
          _ -> []
        end

      # fail-loud-exempt: `ps -o pid=,ppid=` occasionally emits a stray
      # blank/malformed line (kernel scheduling races on some platforms);
      # skipped rather than crashing the reap.
      _ ->
        []
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
  @spec default_git_stash_fn(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def default_git_stash_fn(cwd, slug, reason) do
    with {_out, 0} <-
           System.cmd("git", ["-C", cwd, "rev-parse", "--git-dir"], stderr_to_stdout: true),
         {status, 0} <-
           System.cmd("git", ["-C", cwd, "status", "--porcelain"], stderr_to_stdout: true) do
      tracked_dirty? =
        status
        |> String.split("\n", trim: true)
        |> Enum.any?(&(not String.starts_with?(&1, "??")))

      if tracked_dirty? do
        msg = "queue-#{reason}:#{slug}:#{default_now_fn()}"

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

  # ── Real git_stash_restore_fn: pop a prior queue-timeout stash for slug ──────
  # Producer/consumer contract: `default_git_stash_fn/2` tags a push with
  # "queue-timeout:#{slug}:#{ts}" (see above). This fn resolves the newest
  # `stash@{N}` ref whose message starts with that exact prefix and pops it.
  # No match (first attempt ever, or a slug that never timed out) -> :ok
  # no-op. `git stash list` failing (not a git repo) fails OPEN to :ok — there
  # is nothing to restore. A conflicting pop is the one case that fails LOUD:
  # git retains the stash on a pop conflict, so the returned {:error, reason}
  # names a real, still-present recovery ref for the operator.
  @doc false
  @spec default_git_stash_restore_fn(String.t(), String.t()) :: :ok | {:error, String.t()}
  def default_git_stash_restore_fn(cwd, slug) do
    case System.cmd("git", ["-C", cwd, "stash", "list"], stderr_to_stdout: true) do
      {out, 0} ->
        prefix = "queue-timeout:#{slug}:"

        matches =
          out
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.contains?(&1, prefix))
          |> Enum.map(&extract_stash_ref/1)
          |> Enum.filter(& &1)

        case matches do
          [] ->
            :ok

          [newest | extras] ->
            unless extras == [] do
              IO.puts(
                :stderr,
                "queue: extra #{prefix} stashes remain: " <>
                  Enum.join(extras, ", ") <> " — drop manually"
              )
            end

            case System.cmd("git", ["-C", cwd, "stash", "pop", newest], stderr_to_stdout: true) do
              {_out, 0} ->
                :ok

              {_out, _code} ->
                {:error,
                 "queue: HALTED — stash pop conflict for #{slug}; stash #{newest} retained, resolve manually then re-run"}
            end
        end

      {_out, _code} ->
        :ok
    end
  end

  # `git stash list` line shape: "stash@{N}: On <branch>: <message>" or, with
  # a custom `-m` message (as used here), "stash@{N}: <message>". Extract the
  # leading `stash@{N}` token.
  # fail-loud-exempt: `String.split/3` with `parts: 2` on a non-empty binary
  # ALWAYS returns a non-empty list (worst case: `[line]`) — the `[ref | _]`
  # match is exhaustive for this input; there is no unmatched-condition sink
  # here, only a boolean classification of whether that first token looks
  # like a stash ref.
  @spec extract_stash_ref(String.t()) :: String.t() | nil
  defp extract_stash_ref(line) do
    [ref | _] = String.split(line, ":", parts: 2)
    if String.starts_with?(ref, "stash@{"), do: ref, else: nil
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
      # fail-loud-exempt: absent/malformed gate-result.json means no gate has
      # run yet (or ran before the file existed) — a legitimate "no verdict
      # known" state, not an unexpected error. Callers treat "" as never
      # "clear", so this never masks a real gate failure.
      _ -> ""
    end
  end

  # ── Real gate_base_sha_fn: reads codegen/gate-pending/gate-result.json's
  # short `base_sha` (written by `write_gate_result`, gate-result.sh:197) —
  # mirrors default_gate_verdict_fn's read but surfaces the SHORT sha used
  # for the freshness check against `head_before` (the base the gate
  # actually ran against) in `gate_fresh?/3`
  # (String.starts_with?/2 prefix match, never equality).

  @doc false
  @spec default_gate_base_sha_fn(String.t()) :: String.t()
  def default_gate_base_sha_fn(cwd) do
    path = Path.join([cwd, "codegen", "gate-pending", "gate-result.json"])

    with {:ok, content} <- File.read(path),
         {:ok, %{"base_sha" => base_sha}} <- Jason.decode(content),
         true <- is_binary(base_sha) do
      base_sha
    else
      # fail-loud-exempt: absent/malformed gate-result.json (no gate has run
      # yet, or file predates the base_sha field) is a legitimate "no fresh
      # sha known" state — mirrors default_gate_verdict_fn's identical
      # fail-open contract immediately above. Callers treat "" as never a
      # match for String.starts_with?/2, so this never masks a real check.
      _ -> ""
    end
  end

  # ── Real gate_mtime_fn: mtime of codegen/gate-pending/gate-result.json ─────
  # Paired with default_gate_base_sha_fn/1 in gate_fresh?/3 — rejects a
  # stale "clear" verdict left on disk by an EARLIER cycle sharing the same
  # head_before (two consecutive non-committing attempts have an identical
  # base, so the sha leg alone cannot tell them apart).

  @doc false
  @spec default_gate_mtime_fn(String.t()) :: integer()
  def default_gate_mtime_fn(cwd) do
    path = Path.join([cwd, "codegen", "gate-pending", "gate-result.json"])

    # fail-loud-exempt: an absent/unstattable gate-result.json means no gate
    # record exists — mtime 0 is older than any real spawn `ts`, so callers
    # treat it as never-fresh (fail-closed). Mirrors default_gate_verdict_fn's
    # and default_gate_base_sha_fn's identical fail-open contracts above.
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _reason} -> 0
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
