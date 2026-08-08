defmodule CodegenTestHarness.OrchestrationLoop do
  @moduledoc """
  Deterministic cycle driver: sequences roles, invokes each via
  `RoleResolver.resolve_role/2` → `codegen-call`, runs the gate via
  `LoopGate`, and advances `codegen/gate-pending/cycle-state.json` via the
  existing `cycle-state.sh` contract (GATED → REVIEWED → CURATED →
  COMMITTED).

  Subsumes the in-harness self-orchestration surface's sequencing logic
  (previously encoded across ~25 hooks + the orchestrator role prompt) as
  plain Elixir control flow. Crashes loud on any unexpected state — no
  silent continue, no shim.
  """

  alias CodegenTestHarness.{
    BornDeadDetector,
    BuildLock,
    LoopGate,
    LoopQueue,
    RoleResolver,
    TestCoverageFloor
  }

  # Role-call retry budget. A deterministic failure gets one retry (the
  # historical "failed twice" contract). A failure whose reason matches the
  # shared retryable taxonomy (transport fault / 5xx / overload /
  # "Connection closed mid-response") gets up to 4 attempts with backoff —
  # one API blip must not kill an unattended overnight build.
  @deterministic_attempts 2
  @transient_attempts 4
  # Safety bound on how many `fallback:` rungs a switch_model classification
  # will walk in one role invocation, independent of how long config.yaml's
  # list actually is (RoleResolver.resolve_fallback/3 returning :none ends
  # the walk first in the normal case). Prevents a pathological/typo'd
  # config (e.g. an accidentally-huge fallback list) from looping forever.
  @max_fallback_rungs 5

  @type harness :: String.t()
  @type stack :: String.t()
  @type run_opts :: keyword()

  # Both stacks are developer-first. `committer` is NOT a role — it left the
  # role vocabulary entirely (see pitch "committing is deterministic, not a
  # model call"). The deterministic commit step is the unconditional
  # terminator of `run_roles/4` (its `[]` clause), not a named role in
  # either list — the gate/reviewer/curator tail is common; the commit step
  # follows every sequence regardless of what it ends with.
  @phoenix_roles ~w(developer-phoenix-backend reviewer-phoenix context-curator)
  # Scoping is not a cycle role: the pitch already carries its own deliverable
  # list in the mandatory `scope:` frontmatter field, which the loop reads once
  # (`:pitch_scope`) and threads two ways — as the `{"ev":"files_to_touch",
  # "role":"loop",...}` event that grants the developer its context/*.md Reads,
  # and as the `## Declared Scope` block build_prompt/2 appends for the
  # developer and the reviewer.
  @static_roles ~w(developer-static reviewer-static context-curator)

  @cycle_state_lib Path.expand(
                     "../../../harnesses/claude/hooks/lib/cycle-state.sh",
                     __DIR__
                   )

  @transcript_seq_key :loop_transcript_seq
  @cycle_id_key :loop_cycle_id
  @log_path_key :loop_log_path
  # role => how many times THIS cycle has invoked it. `@transcript_seq_key` is
  # a global counter across all roles, so it cannot answer "is this the
  # developer's first pass or its third?" — the question the whole rework
  # measurement rests on. Rework was previously inferable only by grouping
  # `cycle-summary.jsonl` rows after the fact, which silently reads as "no
  # rework" whenever a row is missing (an aborted call writes none).
  @role_call_count_key :loop_role_call_counts

  @codegen_call_bin Path.expand("../../../codegen-call", __DIR__)
  @codegen_log_bin Path.expand("../../../codegen-log", __DIR__)
  @codegen_advise_bin Path.expand("../../../codegen-advise", __DIR__)
  @codegen_commit_bin Path.expand("../../../codegen-commit", __DIR__)
  @codegen_dir Path.expand("../../..", __DIR__)

  @factcheck_scan_lib Path.expand(
                        "../../../harnesses/claude/hooks/lib/context-factcheck-scan.sh",
                        __DIR__
                      )

  @index_parity_scan_lib Path.expand(
                           "../../../harnesses/claude/hooks/lib/context-index-parity-scan.sh",
                           __DIR__
                         )

  @env_var_scan_lib Path.expand(
                      "../../../harnesses/claude/hooks/lib/env-var-sample-scan.sh",
                      __DIR__
                    )

  @consumption_scan_lib Path.expand(
                          "../../../harnesses/claude/hooks/lib/curator-consumption-scan.sh",
                          __DIR__
                        )

  @doc """
  Returns the ordered role sequence for `stack` (`"phoenix"` or
  `"static"`). Raises on any other stack name.
  """
  @spec role_sequence(stack()) :: [String.t()]
  def role_sequence("phoenix"), do: @phoenix_roles
  def role_sequence("static"), do: @static_roles
  def role_sequence(other), do: raise("OrchestrationLoop: unknown stack #{inspect(other)}")

  @doc """
  Runs one pitch through the full cycle for `opts[:stack]`.

  `opts`:
  - `:harness` — `"claude_code"` (required)
  - `:stack` — `"phoenix"` | `"static"` (required)
  - `:cwd` — project directory the loop operates in (required)
  - `:pitch` — prompt/pitch text passed to the first role (required)
  - `:invoke_fn` — test seam: `(role, harness, ctx, opts -> {:ok, map} | {:error, reason})`,
    defaults to `invoke_role/4` (real `codegen-call` round-trip)
  - `:gate_fn` — test seam: `(cwd, opts -> {verdict, gate_command})`, defaults
    to `LoopGate.run_gate/2`. Called with `gate_opts/1`-derived opts, which
    add `:cycle_log` (THIS cycle's log path) so `LoopGate.run_gate/2` can
    record its verdict into the cycle log — see `LoopGate.run_gate/2` docs.
  - `:log_died_fn` — test seam: `(role, kind, cause, cycle_log -> :ok)`,
    defaults to `default_log_died/4`. Called from `invoke_with_retry/4` on
    every role-invocation failure: `"interrupted"` on the first failure
    (even when the retry recovers), `"aborted"` on the second (retry also
    failed, cycle halts). Writes a `{"ev":"died"}` event into the cycle log
    via `codegen-log append <role> --died <kind>`; fail-loud-non-blocking
    (nil cycle_log or a failed write → no-op / loud stderr, never raises,
    never changes the `{:ok, _}`/`{:error, _}` this function returns).
  - `:log_committed_fn` — test seam: `(role, sha, subject, cycle_log, opts -> :ok)`,
    defaults to `default_log_committed/5`. Called from `invoke_with_retry/4`
    whenever a role's invocation moves `cwd`'s git HEAD (sampled before and
    after via `cycle_base_head/1`): writes a `{"ev":"committed"}` event via
    `codegen-log committed --role <role> --sha <sha> --subject <subject>`.
    The loop asserts on its OWN pre/post HEAD samples (never on this event,
    which a bypassing role could forge) and raises whenever ANY role moves
    HEAD — no role commits anymore; the deterministic commit step
    (`run_commit_step/3`) is the ONLY thing that moves HEAD, and it is not a
    role invocation at all, so it never reaches this guard. See § Enforcement
    in `shared/rules/_core/session-log.md`.
  - `:gate_preflight_fn` — test seam: `(cwd -> resolved)` — resolves the app
    gate at turn 0 before any role runs; defaults to `LoopGate.decide_gate/1`
  - `:preflight_probe_fn` — test seam: `(cwd -> raw_output)` — resolves the
    full set of installed `--agent` role names at turn 0, before any role
    runs; defaults to `default_preflight_probe/1` (a single sentinel
    `codegen-call --agent <bogus>` call parsing claude's "Available agents:"
    error text — zero model turns)
  - `:orientation_preflight_fn` — test seam: `(cwd -> {:clean} | {:violations, String.t()})`,
    defaults to `default_orientation_preflight/1`. Runs at turn 0, right
    after `preflight_roles!/3` and before any role is invoked or paid for —
    the repo-wide sibling of `run_curator_doc_check/6`'s per-curator-turn
    scan. Always shells `context-index-parity-scan.sh <cwd>` (its full-tree
    pass is repo-wide and delta-independent by design — it exists to catch
    drift the diff-scoped check would miss). Additionally shells
    `context-factcheck-scan.sh <cwd>` in its WHOLE-TREE mode (no doc args)
    when `<cwd>/harnesses/claude/manifest.yaml` exists — i.e. only in the
    codegen repo itself, never in a scaffolded downstream app, which has no
    such sentinel and would otherwise newly refuse its build for
    pre-existing rot in its own orientation docs. `preflight_clean_tree!/1`
    already ran before this (turn-0 ordering), so any violation surfaced
    here is proven inherited, not caused by this cycle. `{:violations, v}`
    is CLASSIFIED (`classify_orientation_violations/1`): when every line
    names a curator-writable doc (`context/<basename>.md` or
    `PROJECT_CONTEXT.md`), the loop lazily resolves `context-curator` and
    runs a bounded repair loop (`run_orientation_repair/1`) BEFORE the
    selected suffix — never advancing `CURATED`. Any other shape (a line
    naming `AGENTS.md`/`CLAUDE.md`/another surface, an unparseable line, or
    a MIXED writable/non-writable set) still raises
    `CodegenTestHarness.InfraAbort` via `LoopGate.infra_abort!/2` (exit 3
    under `mix codegen.loop` — halts a `--queue` drain with the pitch left
    untouched in `ready/`) — never a partial repair. See pitch
    `orientation-preflight-routes-to-curator`.
  - `:max_gate_retries` — developer re-runs allowed after a non-clear gate
    before giving up (default 1). This is a FALLBACK bound used only when
    the tree-progress signature is unavailable (non-git `:cwd`, e.g. mocked
    unit tests). When a real git work tree is present, developer re-runs are
    instead bounded by PROGRESS (the working tree must actually change
    between gate runs) up to a hard ceiling of 15 attempts — see
    `do_gate_loop/9`.
  - `:tree_signature_fn` — test seam: `(cwd -> signature)`, defaults to
    `tree_signature/1` (a content-hash of the tracked+untracked working
    tree). Drives the progress bound on developer gate re-runs.
  - `:live_build_root_fn` — test seam: `(-> build_root_path)`, defaults to
    `default_live_build_root_fn/0` (the RUNNING orchestrator process's own
    `_build`, resolved from its current working directory). The
    `:stale_build_heal_fn` never `rm_rf`s a candidate root that resolves to
    this path — nuking the live orchestrator's own build root guarantees the
    next gate entry finds a half-recompiled `_build` and re-triggers the
    same stale signature.
  - `:curator_doc_check_fn` — test seam: `(cwd -> {:clean} | {:violations, String.t()})`,
    defaults to a closure over `default_curator_doc_scan/2` (see
    `run_curator_doc_scan/2`). Runs THREE checks after the
    context-curator role: (1) cross-file index-parity (shells
    `harnesses/claude/hooks/lib/context-index-parity-scan.sh <cwd>`,
    detecting a working-tree `context/*.md` add/delete without matching
    `PROJECT_CONTEXT.md` § Domain Context Files parity — this check can
    NEVER be a per-edit gate: an ADD needs BOTH the file AND its index row,
    so whichever write lands first would deadlock a PreToolUse gate); and
    (2) a factcheck Bash-write backstop (diff-scopes to the current cycle's
    own orientation-doc edits via `changed_orientation_docs/1`, then shells
    `harnesses/claude/hooks/lib/context-factcheck-scan.sh <cwd> <doc>...`
    scoped to exactly those docs), catching a `sed`/`printf>`/`mv` Bash write
    the PreToolUse `context-factcheck-edit-gate` hook (which only fires on
    Edit/Write/MultiEdit) never sees; and (3) a consumption check (shells
    `harnesses/claude/hooks/lib/curator-consumption-scan.sh <cwd> <cycle_log>`)
    asserting that when this cycle captured upstream `{"ev":"learned"}`
    events (developer/reviewer), the curator either routed at least
    one into a durable doc (`context/*.md` or `shared/rules/**.md` — NEVER
    `codegen/rules/**`, a symlink spelling git never emits, see the scan's
    own header comment) or recorded each drop as its own `{"ev":"learned"}`
    event naming the reason. `<cycle_log>` comes from `opts[:cycle_log]`
    (see `gate_opts/1`) — `nil` (no log initialized, e.g. most unit tests)
    skips this leg with `{:clean}`, since a cycle with no log has nothing to
    prove either way. Violations from any of the three checks are joined
    into one message. Empty changed-docs AND clean index-parity AND (no
    cycle_log OR nothing captured) → `{:clean}` without shelling any scan.
    Runs after the context-curator
    role, replacing the dead-under-loop `context-factcheck-curator-stop`
    SubagentStop hook (roles run as main-agent `codegen-call` invocations
    under the loop, so SubagentStop never fires here — same reasoning as
    `run_format_step`) and the commit-time `context-index-parity` hook
    (which only ever dead-ended the committer, which cannot Read/Edit
    `context/*.md`).
  - `:max_curator_doc_cycles` — a GUARANTEED FLOOR of context-curator
    re-invokes allowed after a curator-doc violation (factcheck or
    index-parity) before giving up (default 1: the first rework is always
    granted). Beyond the floor, a rework is granted only when the curator
    provably resolved at least one violation from the prior scan (the
    current violation set is not a superset of the prior one) — a hard
    ceiling (`@repair_progress_ceiling`, 15) bounds this regardless. A
    thrashing or unsatisfiable-by-any-edit violation set dies at the SAME
    turn it dies today; only a converging repair earns extra turns.
    Same posture as `:max_review_cycles`: exhaustion fails the cycle LOUD
    rather than proceeding — `context-curator` is the only role permitted
    to edit these docs, so a violation it did not clear must never travel
    onward as if it had been fixed. The failure is retryable (no terminal
    marker).
  - `:env_var_scan_fn` — test seam: `(cwd -> {:clean} | {:violations, String.t()})`,
    defaults to `default_env_var_scan/1` (shells
    `harnesses/claude/hooks/lib/env-var-sample-scan.sh <cwd>`, which scopes
    the working-tree diff vs HEAD to `*.ex/*.exs` files and flags any newly
    added `System.get_env`/`fetch_env("VAR")` string-literal read whose VAR
    is not declared in BOTH `.env.sample` and `.env.prod.sample`). Runs
    after the developer role (between format and gate), replacing the
    dead-under-loop `env-var-sample-consistency` SubagentStop hook (roles
    run as main-agent `codegen-call` invocations under the loop, so
    SubagentStop never fires here — same reasoning as `run_format_step` and
    `run_curator_doc_check`).
  - `:max_env_var_cycles` — a GUARANTEED FLOOR of developer re-invokes
    allowed after an env-var violation before giving up (default 1: the
    first rework is always granted). Beyond the floor, the same
    progress-past-the-floor extension as `:max_curator_doc_cycles` applies
    (resolved-violation check, `@repair_progress_ceiling` hard cap).
    Exhaustion fails the cycle LOUD (same posture as `:max_curator_doc_cycles`
    and `:max_review_cycles` — none of the three budgets proceeds on
    exhaustion): an undeclared required env var is a real defect the app
    crashes on at runtime, so handing it onward unfixed is not safe.
  - `:lock_path` — per-cwd single-flight lock file, default
    `Path.join([cwd, "codegen", "gate-pending", "queue.lock"])` — the SAME
    physical path `LoopQueueDrain.drain/1` locks, so a bare single build and
    a `--queue` drain mutually exclude on one git tree. Acquired at the very
    start of `run/1` (before any preflight), released in `after` regardless
    of outcome (including a raise). Skipped entirely when the
    `CODEGEN_BUILD_LOCK_HELD=1` env var is set — the bypass a per-pitch
    `codegen-build` child spawned by the drain uses, since the drain already
    holds the outer lock on the identical file.
  - `:pid_alive_fn` — test seam: `(pid_str -> boolean)`, defaults to
    `CodegenTestHarness.BuildLock.default_pid_alive?/1` (`kill -0`
    liveness check). A lock naming a dead pid is reclaimed silently
    (stale-lock recovery); a lock naming a live pid refuses with
    `{:error, reason}` naming the pid.
  - `:orphan_scan_fn` — test seam: `(cwd -> [pid_str])`, defaults to
    `default_orphan_scan/1` (`pgrep -f` matching `mix codegen\\.loop
    .*--cwd=<cwd>`). Runs once, right after lock acquisition — catches an
    orphaned `mix codegen.loop` beam that already released (or never held)
    the lock but is still running. Never auto-kills: a non-empty result
    refuses with `{:error, reason}` naming the pid(s) + a copy-paste
    inspect/reap command. Degrades to `[]` (lock-only enforcement) when
    `pgrep` itself is unavailable.
  - `:cycle_state_get_fn` — test seam: `(cwd -> state_string)` for the
    resume-checkpoint check (see pitch "no whole-build restart when the
    loop dies mid-cycle"), defaults to shelling `cycle-state.sh`'s
    `cycle_state_get`. Only consulted at turn 0, before the clean-tree
    preflight, to decide whether this run continues a prior cycle's
    checkpoint instead of starting fresh.
  - `:read_verdict_fn` — test seam: `(cwd -> :clear | :failed)` for the
    resume-checkpoint check, defaults to `LoopGate.read_verdict/1`. A raise
    (the real function's behavior on an absent/malformed gate-result.json)
    is caught internally and treated as "no checkpoint" — never propagates.
  - `:gate_tree_match_fn` — test seam: `(cwd -> boolean())` for the
    resume-checkpoint tree-match check, defaults to comparing
    `LoopGate.graded_tree_sha_now/1` against
    `LoopGate.gate_result_graded_tree_sha/1` (both non-empty). Also reused
    by the committer's pre-commit re-gate check (`ensure_gate_graded_this_tree!`).
  - `:gate_result_base_sha_fn` — test seam: `(cwd -> sha_string)` for the
    resume-checkpoint HEAD-unmoved cross-check, defaults to
    `LoopGate.gate_result_base_sha/1`.
  - `:log_resume_fn` — test seam: `(resume_role, state -> :ok)`, defaults to
    `default_log_resume/2` (appends a `codegen-log append loop-resume --body`
    observability line to the cycle log; fail-loud-non-blocking).

  Returns `:ok` on COMMITTED + clear gate. Returns `{:error, reason}` on
  any role failure (after one retry), a non-clear gate (after the gate-retry
  bound is exhausted — progress-based, or `:max_gate_retries` when no
  progress signature is available), or an unexpected envelope shape (raised,
  not returned — crash loud).
  """
  @spec with_startup_guard(run_opts(), (-> :ok | {:error, String.t()})) ::
          :ok | {:error, String.t()}
  def with_startup_guard(opts, run_fn) do
    cwd = Keyword.fetch!(opts, :cwd)

    if Keyword.get(opts, :build_lock_held, false) or build_lock_bypassed?() do
      run_fn.()
    else
      lock_path = Keyword.get(opts, :lock_path, default_lock_path(cwd))
      pid_alive_fn = Keyword.get(opts, :pid_alive_fn, &BuildLock.default_pid_alive?/1)

      case BuildLock.acquire(lock_path, "solo", pid_alive_fn) do
        :ok ->
          try do
            case refuse_if_orphan(cwd, opts) do
              :ok -> run_fn.()
              {:error, reason} -> {:error, reason}
            end
          after
            BuildLock.release(lock_path)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec run(run_opts()) :: :ok | {:error, String.t()}
  def run(opts), do: with_startup_guard(opts, fn -> run_body(opts) end)

  defp default_lock_path(cwd), do: Path.join([cwd, "codegen", "gate-pending", "queue.lock"])

  # A `codegen-build` child spawned by `LoopQueueDrain.default_spawn_fn/5`
  # already runs under the DRAIN's outer lock (same physical `queue.lock`
  # file) — it must NOT re-acquire, or every queued pitch would immediately
  # refuse against its own parent's lock. Threaded via env, checked here
  # rather than as a Keyword opt so the real subprocess boundary (env, not
  # in-process Elixir opts) is the actual bypass mechanism.
  defp build_lock_bypassed?, do: System.get_env("CODEGEN_BUILD_LOCK_HELD") == "1"

  defp run_body(opts) do
    harness = Keyword.fetch!(opts, :harness)
    stack = Keyword.fetch!(opts, :stack)
    cwd = Keyword.fetch!(opts, :cwd)
    pitch = Keyword.fetch!(opts, :pitch)

    all_roles = role_sequence(stack)

    # Resume-checkpoint (see pitch "no whole-build restart when the loop
    # dies mid-cycle"): a prior cycle that died AFTER a clear gate leaves a
    # durable, verified checkpoint on disk (gate-result.json + cycle-state.json)
    # even though the loop process itself left no trace. Check for one BEFORE
    # the clean-tree refusal below — a valid checkpoint's dirty tree IS the
    # prior cycle's sanctioned, gate-graded work, and must not be refused by
    # the guard meant for foreign uncommitted changes at a true cycle start.
    # An invalid/absent checkpoint (the overwhelmingly common case: no prior
    # death, or a death before the gate) falls straight through unchanged.
    # A materialized recovery dossier is newer than the old on-disk
    # checkpoint it replaced, so its start role has unconditional precedence.
    resume =
      case Keyword.get(opts, :recovery_role) do
        nil -> resume_checkpoint(cwd, all_roles, opts)
        role -> {:resume, role, "RECOVERED"}
      end

    case resume do
      {:resume, resume_role, state} ->
        roles = resume_suffix(all_roles, resume_role)

        ctx = %{
          cwd: cwd,
          pitch: pitch,
          pitch_scope: Keyword.get(opts, :pitch_scope),
          artifacts: %{resume_state: state},
          base_head: cycle_base_head(cwd)
        }

        run_body_from(harness, cwd, roles, ctx, opts, {resume_role, state})

      :full ->
        # Turn-0 clean-tree precondition: symmetric HEAD guard to
        # verify_committed!'s tail guard. A cycle starting on an
        # already-dirty tree is ambiguous — roles can read, modify, or
        # commit foreign uncommitted changes, and the tail guard can only
        # report the mess after a full (paid) cycle. Refuse here, cheaply,
        # before any role runs or the gate resolves. Overridable via
        # :clean_tree_preflight_fn — existing mocked tests simulate
        # mid-cycle developer output (a real dirty tree BEFORE their
        # stubbed invoke_fn runs) to exercise gate/factcheck/commit-guard
        # behavior in isolation; those are not the "foreign uncommitted
        # changes at true cycle start" this guard exists to catch, so they
        # opt out with a no-op here.
        #
        # `:recovery_mode` (nil | :exact | :advanced | :operator) is the ONE
        # other legitimate reason a cycle may start dirty: recovery
        # materialization (`InterruptedCycleRecovery.materialize/2`) applies
        # the recovered transaction's bytes dirty-and-unstaged onto the
        # current tree BEFORE `OrchestrationLoop.run/1` is ever invoked, so
        # this preflight must not fire for that dirtiness — it is sanctioned,
        # transaction-owned recovered work, not a foreign uncommitted change.
        # A nil recovery_mode (every non-recovery cycle) runs the guard
        # byte-for-byte unchanged.
        unless Keyword.get(opts, :recovery_mode) do
          clean_tree_fn = Keyword.get(opts, :clean_tree_preflight_fn, &preflight_clean_tree!/1)
          clean_tree_fn.(cwd)
        end

        # A stale terminal-state.json from a PRIOR cycle must never leak
        # into this one — a fresh cycle start has produced no deterministic
        # exhaustion yet, so any marker on disk is left over from an
        # earlier, already-concluded cycle. Never unlinked on the `:resume`
        # branch above: exhaustion is terminal, not resumable, so a resumed
        # cycle never legitimately carries one either — but leaving it
        # alone there costs nothing (a resumed cycle only reaches a marker
        # write path via its own fresh exhaustion, same as any other).
        File.rm(Path.join([cwd, "codegen", "gate-pending", "terminal-state.json"]))

        ctx = %{
          cwd: cwd,
          pitch: pitch,
          pitch_scope: Keyword.get(opts, :pitch_scope),
          artifacts: %{},
          base_head: cycle_base_head(cwd)
        }

        run_body_from(harness, cwd, all_roles, ctx, opts, nil)
    end
  end

  # Shared tail of run_body/1 — identical for both the :full and :resume
  # branches once `roles`/`ctx` are settled: mint the cycle log (unless
  # already resumed with a nil slug in tests), preflight the gate + roles,
  # then run. `resume_info` is `{resume_role, state}` on a resumed cycle
  # (logged AFTER the cycle log is minted, below) or `nil` on a full run.
  defp run_body_from(harness, cwd, roles, ctx, opts, resume_info) do
    Process.put(@transcript_seq_key, 0)
    Process.put(@cycle_id_key, Keyword.get(opts, :cycle_id))

    # Cycle-log ownership: this loop is the SOLE creator of the cycle's own
    # session log. A nil slug (many unit tests pass none, cwd is often a
    # synthetic "/tmp/irrelevant") skips init cleanly — no raise, log-path
    # key just stays nil. A present slug that fails to init is fatal: a
    # cycle with no log of its own would otherwise silently append its
    # roles' sections into whatever unrelated log happens to be newest on
    # disk.
    case Keyword.get(opts, :slug) do
      nil ->
        :ok

      slug ->
        stamp = Keyword.get(opts, :stamp)
        log_init_fn = Keyword.get(opts, :log_init_fn, &default_log_init/3)
        Process.put(@log_path_key, log_init_fn.(slug, cwd, stamp))
    end

    log_declared_scope(ctx, cwd, opts)

    case resume_info do
      {resume_role, state} -> log_resume(resume_role, state, opts)
      nil -> :ok
    end

    # Turn-0 gate preflight: resolve the app's gate command BEFORE invoking
    # (and paying for) any role. Resolution-only — decide_gate never executes
    # the gate. An unresolvable gate (missing/empty/stale GATE_COMMAND) raises
    # here, at turn 0, cheaply, instead of mid-cycle after the developer runs.
    # The resolved gate command is stashed into ctx.artifacts so build_prompt/2
    # can thread it into the developer's self-verify instruction — reusing this
    # preflight result instead of re-shelling git inside build_prompt (which
    # would crash the synthetic-cwd ("/tmp/irrelevant") unit tests).
    gate_command = timed_preflight("gate", cwd, fn -> preflight_gate!(cwd, opts) end)
    ctx = put_in(ctx, [:artifacts, :gate_command], gate_command)
    timed_preflight("roles", cwd, fn -> preflight_roles!(roles, cwd, opts) end)

    ctx =
      timed_preflight("orientation", cwd, fn ->
        run_orientation_preflight(cwd, ctx, harness, opts)
      end)

    run_roles(roles, harness, ctx, opts)
  end

  # Times one turn-0 preflight step and records it, then returns the step's
  # own result untouched.
  #
  # Preflight runs before a single role is paid for and recorded NOTHING, so
  # its cost was invisible to every measurement of a build. It is not small:
  # the orientation step alone shells a whole-tree scan of every orientation
  # doc, measured at 72s on this repo before it was made to stop forking per
  # line. Anything that runs at turn 0 of every cycle and cannot be seen is
  # exactly where time hides.
  #
  # Fail-open by construction: a write failure, an absent cycle id, or the
  # synthetic cwd most unit tests pass all skip the record silently. Turn-0
  # preflight decides whether a build starts at all — observability must
  # never be the thing that stops it.
  @spec timed_preflight(String.t(), String.t(), (-> result)) :: result when result: var
  defp timed_preflight(step, cwd, fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - started

    record_preflight_timing(step, cwd, elapsed)

    result
  end

  @spec record_preflight_timing(String.t(), String.t(), integer()) :: :ok
  defp record_preflight_timing(step, cwd, elapsed_ms) do
    cycle_id = Process.get(@cycle_id_key)

    if is_binary(cycle_id) and cycle_id != "" and File.dir?(cwd) do
      line =
        Jason.encode!(%{
          "cycle_id" => cycle_id,
          "step" => step,
          "elapsed_ms" => elapsed_ms,
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })

      dir = Path.join([cwd, "codegen", "logging"])

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(Path.join(dir, "preflight-timings.jsonl"), line <> "\n", [:append]) do
        :ok
      else
        _ -> :ok
      end
    else
      :ok
    end
  end

  # Start-time orphan surfacing: scans for live `mix codegen.loop` beams
  # already bound to THIS cwd — catches the case Move 2's lock alone misses,
  # an orphan that already released (or never held, e.g. crashed mid-run
  # before ever writing) the lock file but is still running (e.g. the
  # overnight `mix codegen.loop` beam that ran 8h past its budget kill).
  # Never auto-kills — refuses + names pids so the operator can inspect
  # before reaping (a hit could legitimately be another operator's build).
  # Fails OPEN only when `pgrep` itself is unavailable (degrades to
  # lock-only enforcement, which remains the primary guard) — every other
  # branch is either a clean pass or a loud refuse.
  defp refuse_if_orphan(cwd, opts) do
    orphan_scan_fn = Keyword.get(opts, :orphan_scan_fn, &default_orphan_scan/1)

    case orphan_scan_fn.(cwd) do
      [] ->
        :ok

      pids when is_list(pids) ->
        {:error,
         "orphan mix codegen.loop process(es) already running for this cwd: " <>
           Enum.join(pids, ", ") <>
           " — refusing to start a second build. Inspect with `ps -p " <>
           Enum.join(pids, ",") <>
           " -o pid,etime,command`, then reap with `kill -9 " <>
           Enum.join(pids, " ") <> "` if confirmed stale."}
    end
  end

  # Real orphan_scan_fn: `pgrep -f` matching `mix codegen.loop .*--cwd=<cwd>`,
  # excluding this process's own OS pid (the current invocation has not yet
  # execed `mix codegen.loop` args into its own cmdline match target when
  # this scan runs from within the `OrchestrationLoop` Elixir process, but
  # exclusion is still applied defensively in case of re-entrant test/embed
  # scenarios).
  @doc false
  @spec default_orphan_scan(String.t()) :: [String.t()]
  def default_orphan_scan(cwd) do
    pattern = "mix codegen\\.loop .*--cwd=#{Regex.escape(cwd)}"

    case System.cmd("pgrep", ["-f", pattern], stderr_to_stdout: true) do
      {output, 0} ->
        self_pid = System.pid()

        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == self_pid))

      # fail-loud-exempt: pgrep exit 1 means "no matches" (its documented
      # not-found contract) — an empty result, not an error.
      {_output, 1} ->
        []

      # fail-loud-exempt: `pgrep` missing from PATH or another exec error —
      # the orphan scan is a secondary guard on top of the per-cwd lock
      # (Move 2, primary). Degrading to lock-only enforcement here is a
      # justified, commented fail-open (documented in the calling doc
      # comment above), not a silent swallow: logged loud on stderr.
      {output, _other_code} ->
        IO.puts(:stderr, "queue: orphan scan skipped — pgrep unavailable: #{output}")
        []
    end
  end

  # Sentinel agent name guaranteed never to be installed — used solely to
  # trigger claude's "--agent '<x>' not found. Available agents: <csv>" error,
  # which enumerates the FULL set of resolvable agents in one no-model-turn
  # probe. Never registered as a real role.
  @preflight_sentinel "__codegen_loop_preflight_probe__"

  # Turn-0 role-resolution preflight: confirms every role in `roles` resolves
  # under `claude --agent <role> --setting-sources user,project` BEFORE any
  # role is invoked (and paid for). A broken/uninstalled role set raises here,
  # naming the missing roles, instead of surfacing mid-cycle as a mis-labeled
  # transient retry (codegen-call's non-zero-exit synthetic-failure path).
  #
  # Reuses the exact `--agent`/`--setting-sources user,project` flag assembly
  # call-dispatch.sh established (single-sourced scope — no Elixir-side
  # duplication). Fails CLOSED: an inconclusive probe (no parseable
  # "Available agents:" line) raises rather than assuming the roles resolve.
  #
  # Two DIFFERENT failures live in this function and only one of them is a
  # verdict about the agent set:
  #
  #   * `{:ok, available}` with a non-empty `missing` — the probe SPOKE and
  #     named a set that omits a required role. That is a real, reproducible
  #     defect (`make install` never ran, an agent was renamed). It raises,
  #     unretried, and must stay that way.
  #
  #   * `:error` — the probe produced no parseable agent list at all. Nothing
  #     was learned about the agents; this is an inconclusive PARSE, not a
  #     missing agent. Its observed causes are transient (a CLI that wrote a
  #     spinner/warning ahead of the error line, a truncated pipe, a slow
  #     cold start), and a single unlucky probe used to kill the whole build
  #     before any role ran. Probe again — `default_preflight_probe/1` costs
  #     zero model turns (the sentinel `--agent` makes claude exit 1 before
  #     any turn), so a retry is free. Only a SECOND inconclusive probe
  #     raises, preserving the fail-closed posture for a genuinely
  #     unparseable environment.
  @preflight_probe_attempts 2

  defp preflight_roles!(roles, cwd, opts), do: preflight_roles!(roles, cwd, opts, 1)

  defp preflight_roles!(roles, cwd, opts, attempt) do
    probe_fn = Keyword.get(opts, :preflight_probe_fn, &default_preflight_probe/1)

    output = probe_fn.(cwd)

    case parse_available_agents(output) do
      {:ok, available} ->
        missing = Enum.reject(roles, &(&1 in available))

        if missing != [] do
          raise "OrchestrationLoop: required role agent(s) not resolvable: " <>
                  Enum.join(missing, ", ") <>
                  ". Available: " <>
                  Enum.join(available, ", ") <>
                  ". Run 'make install' to (re)install role agents."
        end

        :ok

      :error when attempt < @preflight_probe_attempts ->
        IO.puts(
          :stderr,
          "OrchestrationLoop: role-agent preflight probe returned no agent list " <>
            "(attempt #{attempt}/#{@preflight_probe_attempts}) — re-probing: " <>
            String.slice(output, 0, 400)
        )

        preflight_roles!(roles, cwd, opts, attempt + 1)

      :error ->
        raise "OrchestrationLoop: could not confirm role-agent resolution (preflight probe " <>
                "returned no agent list after #{@preflight_probe_attempts} attempts): " <>
                String.slice(output, 0, 400)
    end
  end

  # Real probe: invokes codegen-call with the sentinel --agent so claude exits
  # 1 immediately (before any model turn) with the full "Available agents:"
  # list. Returns the raw combined output for parse_available_agents/1.
  defp default_preflight_probe(cwd) do
    unless File.exists?(@codegen_call_bin) do
      raise "OrchestrationLoop: codegen-call not found at #{@codegen_call_bin}"
    end

    # codegen-call validates --model/--effort in pure bash BEFORE dispatch
    # (call-dispatch.sh :? guards), regardless of the sentinel --agent value
    # below causing an immediate exit 1 with zero model turns. These must be
    # present and valid even though no real model call ever executes.
    args = [
      "--harness=claude_code",
      "--model=sonnet",
      "--effort=low",
      "--agent=#{@preflight_sentinel}",
      "PING"
    ]

    env = [{"CODEGEN_DIR", @codegen_dir}]

    {output, _exit_code} =
      System.cmd(@codegen_call_bin, args, stderr_to_stdout: true, env: env, cd: cwd)

    output
  end

  # Parses "Available agents: a, b, c" out of raw probe output. Returns
  # {:ok, [String.t()]} on a match, :error when no such line is present
  # (inconclusive — CLI missing, network error, unexpected format).
  defp parse_available_agents(output) do
    case Regex.run(~r/Available agents:\s*(.+)/, output) do
      [_, csv] ->
        agents =
          csv
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, agents}

      nil ->
        :error
    end
  end

  # Turn-0 repo-wide orientation-doc preflight: the sibling of
  # run_curator_doc_check/6's per-curator-turn scan, moved earlier so a cycle
  # catches INHERITED drift at $0 instead of dying at the curator step after
  # developer+gate+reviewer+curator have all been paid for. Runs
  # AFTER preflight_clean_tree!/1 (called earlier in run_body/1), so any
  # violation surfaced here is proven pre-existing at HEAD, not caused by
  # this cycle's own edits — attribution is structural, not heuristic.
  #
  # `{:violations, v}` is CLASSIFIED, not unconditionally aborted:
  # `classify_orientation_violations/1` partitions the complete line set.
  # Every line naming a curator-writable doc (`context/<basename>.md` or
  # `PROJECT_CONTEXT.md`) → lazily resolve `context-curator`
  # (`preflight_roles!/3`, same fail-loud contract) and run a bounded repair
  # loop via `run_orientation_repair/1` — the owner of this exact drift
  # class already repairs it post-reviewer (`run_curator_doc_check/6`), so
  # inherited drift gets the same treatment instead of a manual exit-3 halt.
  # Any other shape — `AGENTS.md`/`CLAUDE.md`/another surface, an
  # unparseable line, or a MIXED writable/non-writable set — still raises
  # `InfraAbort` via the EXACT prior text, unconditionally: NEVER a partial
  # repair. See pitch `orientation-preflight-routes-to-curator`.
  @spec run_orientation_preflight(String.t(), map(), harness(), run_opts()) :: map()
  defp run_orientation_preflight(cwd, ctx, harness, opts) do
    preflight_fn = Keyword.get(opts, :orientation_preflight_fn, &default_orientation_preflight/1)

    case preflight_fn.(cwd) do
      {:clean} ->
        ctx

      {:violations, violations} ->
        case classify_orientation_violations(violations) do
          :repairable ->
            IO.puts(
              :stderr,
              "codegen.loop: orientation-doc preflight found repairable drift — " <>
                "invoking context-curator"
            )

            preflight_roles!(["context-curator"], cwd, opts)

            case run_orientation_repair(%{
                   phase: :turn0,
                   scan_fn: fn -> preflight_fn.(cwd) end,
                   curator_role: "context-curator",
                   harness: harness,
                   ctx: ctx,
                   opts: opts,
                   cycle: 0,
                   prev_violations: nil,
                   seed_violations: violations,
                   on_clean: fn repaired_ctx, repair_ran? ->
                     if repair_ran? do
                       IO.puts(
                         :stderr,
                         "codegen.loop: orientation-doc preflight repaired — continuing"
                       )
                     end

                     repaired_ctx
                   end,
                   on_failure: &turn0_repair_exhausted/3
                 }) do
              {:error, reason} ->
                raise "OrchestrationLoop: #{reason}"

              %{} = repaired_ctx ->
                repaired_ctx
            end

          {:not_repairable, reason} ->
            LoopGate.infra_abort!(
              "orientation-doc-preflight",
              "#{violations} — orientation docs were already drifted at HEAD; this build " <>
                "introduced nothing. Fix the drift on develop, then re-run. " <>
                "(#{reason})"
            )
        end
    end
  end

  # A single scanner-authored (never manually maintained) map from the
  # scanner's own `<name>: ` prefix to itself — used ONLY to strip the
  # prefix before reading the doc-path token; an unrecognized prefix means
  # the grammar changed under us and must be treated as ambiguous (fail
  # closed), never guessed at.
  @orientation_scanner_prefixes [
    "context-index-parity-scan: ",
    "context-factcheck-scan: "
  ]

  # Extracts the violation's target doc path from one scanner line. The doc
  # path is ALWAYS the first whitespace-delimited token immediately after
  # the scanner-name prefix — never a whole-line substring scan, which would
  # misattribute a factcheck violation ABOUT `AGENTS.md` (whose message text
  # can embed an unrelated `context/*.md` claim path) to a curator-writable
  # doc. `:ambiguous` on an unknown prefix, an empty remainder, or a
  # trailing `:<digits>` stripped down to nothing.
  @spec orientation_violation_target(String.t()) :: {:ok, String.t()} | :ambiguous
  defp orientation_violation_target(line) do
    prefix = Enum.find(@orientation_scanner_prefixes, &String.starts_with?(line, &1))

    case prefix do
      nil ->
        :ambiguous

      _ ->
        remainder = String.trim_leading(line, prefix)

        case String.split(remainder, ~r/\s+/, parts: 2) do
          [token | _] when token != "" ->
            {:ok, Regex.replace(~r/:\d+\z/, token, "")}

          _ ->
            :ambiguous
        end
    end
  end

  # A curator-writable orientation doc: `PROJECT_CONTEXT.md` exactly, or a
  # SINGLE-LEVEL `context/<basename>.md` (never nested — the scanner enum
  # walks `context/` with `-maxdepth 1`, so a nested path is an unobserved
  # shape and permitting it would silently widen the curator's authority).
  @spec curator_writable_doc?(String.t()) :: boolean()
  defp curator_writable_doc?(path) do
    path == "PROJECT_CONTEXT.md" or Regex.match?(~r{\Acontext/[a-zA-Z0-9_-]+\.md\z}, path)
  end

  # Partitions the COMPLETE non-blank violation-line set. `:repairable` only
  # when every single line names a curator-writable doc; the first
  # non-writable or unparseable line short-circuits to `{:not_repairable,
  # reason}` for the WHOLE set — a mixed set is never partially repaired.
  @spec classify_orientation_violations(String.t()) ::
          :repairable | {:not_repairable, String.t()}
  defp classify_orientation_violations(text) do
    case text |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) do
      [] ->
        {:not_repairable, "blank violation payload"}

      lines ->
        Enum.reduce_while(lines, :repairable, fn line, :repairable ->
          case orientation_violation_target(line) do
            {:ok, path} ->
              if curator_writable_doc?(path) do
                {:cont, :repairable}
              else
                {:halt, {:not_repairable, "non-curator-writable target: #{line}"}}
              end

            :ambiguous ->
              {:halt, {:not_repairable, "unparseable violation target: #{line}"}}
          end
        end)
    end
  end

  # Real implementation: index-parity's full-tree pass always runs (cheap —
  # a single git diff/ls-files call, repo-wide by design). The factcheck
  # whole-tree pass (no doc args — scans the FULL fixed orientation-doc set,
  # not diff-scoped) is sentinel-gated to codegen's own layout
  # (`<cwd>/harnesses/claude/manifest.yaml`), mirroring
  # context-index-parity-scan.sh's own full-tree gate (`index_path ==
  # "PROJECT_CONTEXT.md" && harnesses/claude/manifest.yaml present`) — a
  # scaffolded downstream app has no such sentinel and stays on today's
  # byte-for-byte behavior (delta + phantom-ref only, both already
  # effectively no-ops at a clean turn 0). Reuses
  # combine_curator_doc_results/2, the exact joiner the curator step uses.
  defp default_orientation_preflight(cwd) do
    unless File.exists?(@index_parity_scan_lib) do
      raise "OrchestrationLoop: context-index-parity-scan.sh not found at #{@index_parity_scan_lib}"
    end

    index_parity_result =
      case System.cmd("bash", [@index_parity_scan_lib, cwd], stderr_to_stdout: true) do
        {_out, 0} ->
          {:clean}

        {out, 1} ->
          {:violations, String.trim(out)}

        {out, code} ->
          raise "OrchestrationLoop: context-index-parity-scan.sh exited #{code} (expected 0 or 1): #{out}"
      end

    factcheck_result =
      if File.exists?(Path.join(cwd, "harnesses/claude/manifest.yaml")) do
        unless File.exists?(@factcheck_scan_lib) do
          raise "OrchestrationLoop: context-factcheck-scan.sh not found at #{@factcheck_scan_lib}"
        end

        case System.cmd("bash", [@factcheck_scan_lib, cwd], stderr_to_stdout: true) do
          {_out, 0} ->
            {:clean}

          {out, 1} ->
            {:violations, String.trim(out)}

          {out, code} ->
            raise "OrchestrationLoop: context-factcheck-scan.sh exited #{code} (expected 0 or 1): #{out}"
        end
      else
        {:clean}
      end

    combine_curator_doc_results(index_parity_result, factcheck_result)
  end

  # Resolves the app gate at turn 0 via the :gate_preflight_fn seam (default
  # LoopGate.decide_gate/1). Reuses the exact same resolution path the later
  # gate run takes, so it cannot pass-then-fail. Rescues
  # the __GATE_UNRESOLVED__ RuntimeError and re-raises with an actionable hint.
  # Returns the resolved gate command string when the seam's result is a
  # {gate, mode, timeout} tuple (real LoopGate.decide_gate/1 shape); nil when
  # a test override returns some other shape — gate_command is an optional
  # enrichment (self-verify prompt text), not a required contract:
  # build_prompt/2 tolerates its absence.
  defp preflight_gate!(cwd, opts) do
    preflight_fn = Keyword.get(opts, :gate_preflight_fn, &default_gate_preflight/1)

    try do
      case preflight_fn.(cwd) do
        {gate, _mode, _timeout} when is_binary(gate) ->
          gate

        # fail-loud-exempt: non-tuple test-seam overrides (:ok, etc.) are a
        # legitimate "no gate command to thread" — optional enrichment only.
        _other ->
          nil
      end
    rescue
      e in RuntimeError ->
        reraise(
          "LoopGate preflight: app gate unresolved at #{cwd}/.claude/gate-config.sh " <>
            "— add GATE_COMMAND (e.g. \"make ci\") or re-integrate via codegen-scaffold. " <>
            "(underlying: #{Exception.message(e)})",
          __STACKTRACE__
        )
    end
  end

  defp default_gate_preflight(cwd), do: LoopGate.decide_gate(cwd)

  # Runs each role in sequence up to (not including) the gate-dependent
  # tail (reviewer onward); the gate step is interleaved between the
  # developer role and the reviewer role.
  #
  # `committer` is NOT a role — it left `@phoenix_roles`/`@static_roles`
  # (see pitch "committing is deterministic, not a model call"). The commit
  # step is now the UNCONDITIONAL terminator of every role sequence: it
  # runs here, in the `[]` clause, rather than being dispatched as a named
  # role. No-ship-on-a-gate-that-didn't-grade-this-tree still applies —
  # `ensure_gate_graded_this_tree!/5` intercepts before the commit itself,
  # exactly as it did when `committer` was the head of a non-empty list.
  defp run_roles([], harness, ctx, opts) do
    ensure_gate_graded_this_tree!(ctx, [], harness, opts, 0)
  end

  defp run_roles([role | rest], harness, ctx, opts)
       when role == "reviewer-phoenix" or role == "reviewer-static" do
    # Reviewer's first pass routes through invoke_reviewer/4 — unlike every
    # other role clause below, this one captures the loop-derived
    # ## Files Modified set BEFORE invoking the role, not after (see pitch
    # "reviewer handoff names the files under review"). The captured set is
    # stashed on `ctx` for handle_review/7's re-review pass to reuse the seam.
    with {:ok, result, ctx} <- invoke_reviewer(role, harness, ctx, opts) do
      ctx = put_in(ctx, [:artifacts, role], result)
      handle_review(role, result, rest, harness, ctx, opts, 0)
    end
  end

  defp run_roles([role | rest], harness, ctx, opts) when role == "context-curator" do
    # Curator-stage-entry pre-scan: run the SAME doc-integrity scan
    # `run_curator_doc_check/6` runs post-turn, but BEFORE the first curator
    # invocation, so a violation ALREADY present at curator-stage entry
    # (developer/reviewer edits that happened earlier this cycle) reaches
    # the FIRST curator prompt instead of costing a first empty call plus a
    # second paid rework respawn. See pitch
    # `a-deterministic-doc-check-costs-no-extra-turn`. `run_curator_doc_check/6`
    # remains the authoritative POST-turn backstop below (unconditionally) —
    # this pre-scan only changes WHEN a same-cycle violation first reaches a
    # curator prompt, never what counts as a violation or how repair is
    # bounded (`run_orientation_repair/1` is the single shared engine both
    # legs use).
    #
    # No-op-curator-spawn-when-nothing-was-learned: read the cycle's own
    # log for the mechanical learning signal. `:learned` or `:absent`
    # (fail-SAFE default — a missing/unreadable signal is never read as
    # "skip") always spawn the curator: clean pre-scan → one normal
    # invocation; violating pre-scan → one invocation seeded with the
    # violation text (via the shared repair engine, cycle 0). `:no_learning`
    # (every role that ran this cycle honestly declared, on the record, that
    # it learned nothing durable) skips the LLM spawn ONLY when the pre-scan
    # is clean — a pre-existing doc violation still forces exactly one real
    # curator spawn for rework, seeded the same way.
    signal_fn =
      Keyword.get(opts, :curator_learning_signal_fn, &LoopGate.curator_learning_signal/1)

    log_file = Process.get(@log_path_key)
    signal = signal_fn.(log_file)

    # Move 3 (pitch "hand each role the material its job needs"): stash the
    # cycle log's typed `ev:learned` events on ctx BEFORE the curator is
    # invoked — the loop already reads this same log at `signal_fn.(log_file)`
    # above to decide WHETHER to spawn the curator; this reuses that log
    # read to hand over WHAT to curate too. build_prompt/2 renders one of
    # three distinct outcomes (found / log-read-but-empty / log-unreadable)
    # under `## Learnings to route` — never a silent omission that a
    # swallowed read error could be confused with an honest empty cycle
    # (D12).
    learnings_fn = Keyword.get(opts, :curator_learnings_fn, &LoopGate.curator_learnings/1)
    ctx = put_in(ctx, [:artifacts, :curator_learnings], {learnings_fn.(log_file), log_file})

    case run_curator_doc_scan(ctx.cwd, opts) do
      {:clean} ->
        case signal do
          :no_learning ->
            run_format_step(ctx.cwd, opts)
            run_curator_doc_check(role, rest, harness, ctx, opts, 0)

          _learned_or_absent ->
            with {:ok, result} <- invoke_with_retry(role, harness, ctx, opts) do
              ctx = put_in(ctx, [:artifacts, role], result)
              run_format_step(ctx.cwd, opts)
              run_curator_doc_check(role, rest, harness, ctx, opts, 0)
            end
        end

      {:violations, violations} ->
        classify_fn = Keyword.get(opts, :text_classify_fn, &LoopGate.classify_failure/1)

        if classify_fn.(violations) == :infra do
          LoopGate.infra_abort!(
            "curator-doc-check",
            "unsatisfiable by any curator edit (classified :infra) — #{violations}"
          )
        else
          run_curator_doc_check_rework(
            role,
            rest,
            harness,
            ctx,
            opts,
            0,
            Keyword.get(opts, :max_curator_doc_cycles, 1),
            violations,
            nil
          )
        end
    end
  end

  defp run_roles([role | rest], harness, ctx, opts) do
    with {:ok, result} <- invoke_with_retry(role, harness, ctx, opts) do
      ctx = put_in(ctx, [:artifacts, role], result)

      cond do
        developer_role?(role) ->
          run_format_step(ctx.cwd, opts)
          run_env_var_step(role, rest, harness, ctx, opts, 0)

        true ->
          run_roles(rest, harness, ctx, opts)
      end
    end
  end

  defp developer_role?(role), do: String.starts_with?(role, "developer-")

  defp reviewer_role?(role), do: String.starts_with?(role, "reviewer-")

  # No-ship-on-a-gate-that-didn't-grade-this-tree: runs immediately BEFORE
  # the deterministic commit step (keyed on the step about to run, not its
  # predecessor, so it holds for both the phoenix and static sequences — the
  # context-curator, `run_format_step`, and env-var steps are all sequenced
  # ahead of the commit step in both). A tree that changed since the last
  # gate ran (curator doc edits, formatting, or a destructive revert like
  # the incident that motivated this guard) means the recorded verdict no
  # longer describes what's about to be committed — re-gate to restamp a
  # verdict for the CURRENT tree before the commit ever runs.
  #
  # Match (or no comparable signature — non-git cwd, or no prior gate has
  # run in this cycle's opts, e.g. most mocked unit tests) → proceed
  # straight to the commit step. Stale → re-gate via the same
  # `LoopGate.run_gate/2` contract the primary gate loop uses. Clear on
  # re-gate → proceed. Non-clear → route through the SAME developer-rework
  # shape `do_gate_loop/9` uses (fold the gate failure reason + rework brief
  # into context, re-invoke the developer, re-format, re-check), bounded by
  # `:max_final_gate_cycles` (default 1 — separate from `:max_gate_retries`;
  # this is a pre-commit backstop, not the primary gate loop). Exhaustion →
  # `{:error, reason}`, no commit.
  defp ensure_gate_graded_this_tree!(ctx, rest, harness, opts, cycle) do
    case gate_tree_match?(ctx.cwd, opts) do
      true ->
        run_commit_step(ctx, rest, opts)

      false ->
        max_cycles = Keyword.get(opts, :max_final_gate_cycles, 1)

        if cycle < max_cycles do
          rework_final_gate(ctx, rest, harness, opts, cycle)
        else
          {:error,
           "pre-commit re-gate: tree changed since the gate ran and the gate stayed non-clear " <>
             "after #{cycle + 1} rework attempt(s) — refusing to run the commit step on a tree " <>
             "the gate never graded clear (loop_failed, never a false loop_committed)."}
        end
    end
  end

  # Dispatches the `:gate_tree_match_fn` test seam; defaults to comparing
  # `LoopGate.gate_result_graded_tree_sha/1` (what the last gate run
  # stamped) against `LoopGate.graded_tree_sha_now/1` (the tree right now).
  # `""` on either side (non-git cwd, or no gate has run yet) is treated as
  # "nothing to compare" → true, matching the fail-open sentinel every
  # other content-signature check in this module already uses.
  defp gate_tree_match?(cwd, opts) do
    match_fn = Keyword.get(opts, :gate_tree_match_fn, &default_gate_tree_match?/1)
    match_fn.(cwd)
  end

  defp default_gate_tree_match?(cwd) do
    graded = LoopGate.gate_result_graded_tree_sha(cwd)
    current = LoopGate.graded_tree_sha_now(cwd)

    graded == "" or current == "" or graded == current
  end

  # The commit step is DETERMINISTIC — no model call, no `invoke_with_retry`
  # retry ladder, no role artifact. Shells `codegen-commit --subject <sealed>
  # --cwd <ctx.cwd>` (the single implementation shared with `/ready` and
  # `pitch-format-validator.sh`), then runs the IDENTICAL post-commit
  # verification chain the paid committer role used to be checked against —
  # `verify_committed!/2` is unchanged, because it was always re-deriving
  # the loop's own guarantee from git state, never trusting the role's
  # return. See pitch "committing is deterministic, not a model call".
  #
  # `rest` is always `[]` here (the commit step is the unconditional
  # terminator of `run_roles/4`) — kept as a parameter only so a future
  # sequence change does not have to rediscover this call shape.
  defp run_commit_step(ctx, _rest, opts) do
    commit_fn = Keyword.get(opts, :commit_fn, &default_commit_fn/2)
    subject = Keyword.get(opts, :commit_subject)

    case commit_fn.(ctx.cwd, subject) do
      {:ok, _output} ->
        # Structural gap #9 (unchanged): a successful commit_fn return does
        # NOT by itself prove a commit landed on the RIGHT tree — VERIFY the
        # working tree is actually clean and exactly one commit advanced
        # base_head. A dirty tree here means codegen-commit's own internal
        # guards (empty index, backward-roll, gate-verdict) already refused
        # and commit_fn should have returned {:error, _} — this is the same
        # belt-and-braces posture the loop has always applied post-committer.
        verify_committed!(ctx.cwd, ctx.base_head)

        # `{"ev":"committed"}` — loop-authored (never role-authored; no role
        # invocation happened here at all). post_head is sampled fresh
        # rather than reusing verify_committed!'s internal read, since this
        # is a distinct concern (observability event vs correctness guard).
        # nil post_head (non-git cwd, e.g. most mocked unit tests) skips the
        # event entirely — `codegen-log committed` requires a non-empty
        # `--sha`, and there is nothing real to attribute anyway.
        case cycle_base_head(ctx.cwd) do
          nil ->
            :ok

          post_head ->
            commit_subject = git_commit_subject(ctx.cwd, post_head)
            log_committed("loop", post_head, commit_subject, opts)
        end

        advance_cycle_state_step("COMMITTED", ctx, opts)
        :ok

      {:error, reason} ->
        {:error, "codegen-commit refused: #{reason} (loop_failed, never a false loop_committed)"}
    end
  end

  # Default `:commit_fn` — shells `codegen-commit --subject <subject> --cwd
  # <cwd>`. `Mix.Tasks.Codegen.Loop.resolve_commit_subject!/2` is the ONE
  # real production caller of `OrchestrationLoop.run/1` (verified: no other
  # `lib/` call site exists) and it ALWAYS resolves + validates a subject
  # BEFORE this function is ever reached — so a nil subject here can only
  # mean either a genuine defect in that caller, or a synthetic/non-git test
  # cwd exercising role-sequencing logic that never intended to reach a real
  # commit at all.
  #
  # Non-git `cwd` (`File.dir?` false, or `git rev-parse` fails — the
  # synthetic "/tmp/irrelevant" paths the large majority of this module's
  # OWN test suite uses) fails OPEN here, mirroring `cycle_base_head/1` and
  # `verify_committed!/2`'s own documented fail-open posture for the exact
  # same non-git-cwd case: "only a real git work tree can be verified...
  # nothing to verify there." A REAL git cwd with a nil subject IS the
  # genuine defect case — raise loud rather than shell a broken invocation.
  @spec default_commit_fn(String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  defp default_commit_fn(cwd, nil) do
    if File.dir?(cwd) and
         match?({_, 0}, System.cmd("git", ["rev-parse", "HEAD"], cd: cwd, stderr_to_stdout: true)) do
      raise "OrchestrationLoop: run_commit_step reached a real git cwd with no commit_subject — " <>
              "resolve_commit_subject!/2 should have refused this cycle before any role ran."
    else
      {:ok, "no-op (non-git cwd, no commit_subject — test seam)"}
    end
  end

  defp default_commit_fn(cwd, subject) do
    case System.cmd(@codegen_commit_bin, ["--subject", subject, "--cwd", cwd],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, _nonzero} -> {:error, String.trim(output)}
    end
  end

  # Re-gates the CURRENT tree (the same `:gate_fn` contract `do_gate_loop/9`
  # uses) before the commit step runs. Clear → proceed to the commit step
  # (restamped `gate-result.json` now matches). Non-clear → resolve the
  # OWNER of the failure via `resolve_gate_owner/2` (the same owner-routing
  # `do_gate_loop/9`'s owner arm already uses — a `context/*.md` /
  # `PROJECT_CONTEXT.md` witness routes to `context-curator`, everything
  # else keeps routing to the cycle's developer), fold the gate failure
  # into context (mirrors `do_gate_loop/9`'s rework shape), then recurse
  # into `ensure_gate_graded_this_tree!/5` for another match check + gate
  # cycle. No developer role in this cycle's artifacts (should not happen
  # in practice — a developer always runs before the commit step in both
  # role sequences) → treat as exhausted rather than crash on a nil
  # dev_role; owner resolution never runs without a dev_role to fall back
  # to.
  defp rework_final_gate(ctx, rest, harness, opts, cycle) do
    gate_fn = Keyword.get(opts, :gate_fn, &LoopGate.run_gate/2)
    max_cycles = Keyword.get(opts, :max_final_gate_cycles, 1)
    # gate_owner_fn defaults to resolve_gate_owner/2 (see below) — kept as
    # a seam so tests can inject a curator-owned witness deterministically.

    case gate_fn.(ctx.cwd, gate_opts(opts, ctx)) do
      {:clear, _gate_cmd} ->
        run_commit_step(ctx, rest, opts)

      {:failed, _gate_cmd} ->
        # GATED resume artifacts start at reviewer, not developer. The stack
        # is therefore the authoritative developer source for rework.
        dev_role = resolve_developer_role(role_sequence(Keyword.fetch!(opts, :stack)))
        owner_fn = Keyword.get(opts, :gate_owner_fn, &resolve_gate_owner/2)
        rework_role = owner_fn.(ctx.cwd, dev_role)

        reason = gate_failure_reason(ctx.cwd)
        brief = capture_rework_brief(ctx.cwd, opts)

        # Mirrors `do_gate_loop_rework/9`'s give-up-boundary escalation:
        # this rework is the FINAL one `ensure_gate_graded_this_tree!/5`
        # will allow when the next cycle (cycle + 1) would already meet or
        # exceed `max_final_gate_cycles` and be refused.
        final_attempt? = cycle + 1 >= max_cycles

        retry_ctx =
          ctx
          |> put_in([:artifacts, :last_failure_reason], reason)
          |> put_in([:artifacts, :rework_brief], brief)
          |> maybe_escalate_model(rework_role, harness, opts, final_attempt?)
          |> maybe_advise(rework_role, harness, opts, final_attempt?, %{
            stage: "final_gate_rework",
            attempt: cycle + 1,
            ceiling: max_cycles
          })

        with {:ok, result} <- invoke_with_retry(rework_role, harness, retry_ctx, opts) do
          ctx =
            retry_ctx
            |> put_in([:artifacts, rework_role], result)
            |> update_in([:artifacts], &Map.delete(&1, :escalated_model))
            |> update_in([:artifacts], &Map.delete(&1, :advisor_plan))

          run_format_step(ctx.cwd, opts)
          ensure_gate_graded_this_tree!(ctx, rest, harness, opts, cycle + 1)
        end

      {other, _gate_cmd} ->
        raise "OrchestrationLoop: unexpected gate verdict #{inspect(other)}"
    end
  end

  # Cycle-base HEAD captured before any role runs. nil when cwd is not a git
  # work tree or the branch is unborn (zero commits) — the work-produced check
  # is then skipped (nothing to compare against); the clean-tree assertion still
  # applies. Real loop runs always operate in the scaffolded repo with commits.
  defp cycle_base_head(cwd) do
    with true <- File.dir?(cwd),
         {out, 0} <-
           System.cmd("git", ["rev-parse", "HEAD"], cd: cwd, stderr_to_stdout: true) do
      case String.trim(out) do
        "" -> nil
        sha -> sha
      end
    else
      _ -> nil
    end
  end

  # Sentinel resume target for the deterministic commit step — NOT a role
  # name (see pitch "committing is deterministic, not a model call": the
  # commit step left the role vocabulary entirely). Handled specially by
  # `resolve_resume_role/2` (bypasses the `roles`-membership search — the
  # sentinel is never a member of any stack's role list) and `resume_suffix/2`
  # (resolves directly to `[]`, since `run_roles([], ...)` already runs the
  # commit step unconditionally).
  @commit_step_sentinel "__commit_step__"

  @doc """
  Renders a `resume_role_for_recovery/3` result for a human-facing log line
  — `@commit_step_sentinel` (an internal, non-role marker) prints as `"the
  commit step"`; every real role name passes through unchanged.
  """
  @spec display_resume_role(String.t()) :: String.t()
  def display_resume_role(@commit_step_sentinel), do: "the commit step"
  def display_resume_role(role), do: role

  # Maps a completed cycle-state to the role the resumed cycle must start
  # from. Deliberately NOT `cycle-state.sh`'s `cycle_state_role` (that helper
  # returns "" for GATED and is shaped for human block-message text, not a
  # role-sequence lookup) — this is a distinct, resume-specific mapping.
  @spec resume_role_for_state(String.t()) :: String.t() | nil
  defp resume_role_for_state("GATED"), do: "reviewer"
  defp resume_role_for_state("REVIEWED"), do: "context-curator"
  defp resume_role_for_state("CURATED"), do: @commit_step_sentinel
  defp resume_role_for_state(_other), do: nil

  # Resolves a state's abstract "reviewer" target against the STACK-SPECIFIC
  # role name actually present in `roles` (role_sequence/1 emits
  # "reviewer-phoenix" or "reviewer-static", never a bare "reviewer") — never
  # hardcode either variant here.
  #
  # `@commit_step_sentinel` bypasses the `roles`-membership search entirely
  # and resolves unconditionally — the commit step is never a member of any
  # stack's role list (it left the role vocabulary; see
  # `@commit_step_sentinel` doc above).
  @spec resolve_resume_role(String.t(), [String.t()]) :: String.t() | nil
  defp resolve_resume_role(@commit_step_sentinel, _roles), do: @commit_step_sentinel

  defp resolve_resume_role("reviewer", roles) do
    Enum.find(roles, &(&1 == "reviewer-phoenix" or &1 == "reviewer-static"))
  end

  defp resolve_resume_role(role, roles), do: Enum.find(roles, &(&1 == role))

  # Recovery-mode role selection: distinct from `resume_checkpoint/3` above
  # (that one resumes an UNCHANGED gate-graded cycle-state checkpoint; this
  # one resumes a MATERIALIZED recovery transaction, whose recovered bytes
  # were just applied dirty-and-unstaged onto the current tree — see pitch
  # "restarted builds resume owned work"). Maps a
  # `InterruptedCycleRecovery.materialize/2` disposition to the role the
  # resumed cycle must start from, resolved against the STACK-SPECIFIC
  # `roles` list (mirrors `resolve_resume_role/2`'s reviewer-alias handling).
  #
  #   * `:exact` (current HEAD == recovered transaction's source base, tree
  #     byte-identical to the recorded recovery tree) — the checkpoint
  #     recorded at parking time is still trustworthy. `cycle_state` maps via
  #     `resume_role_for_state/1` exactly like an ordinary in-process resume
  #     (GATED->reviewer, REVIEWED->context-curator, CURATED->committer). A
  #     failed/absent cycle_state (the pitch died before or during the
  #     developer role, or the parked cycle never reached a gate) starts at
  #     developer — the recovered bytes are the developer's own
  #     already-done work, re-entered for a fresh gate/review pass rather
  #     than rebuilt from a blank pitch.
  #   * `:advanced` (HEAD has moved past the recorded source base) or
  #     `:operator` (dirty same-scope operator edits alongside the recovered
  #     transaction) — intervening history or a second version of the work
  #     can stale the recovered transaction's assumptions. Always reconciles
  #     at the developer role, the head of both stacks' sequences — never
  #     resumes straight to reviewer/committer on a base that moved.
  @spec resume_role_for_recovery(:exact | :advanced | :operator, String.t() | nil, [String.t()]) ::
          String.t()
  def resume_role_for_recovery(:exact, cycle_state, roles) do
    target = resume_role_for_state(cycle_state || "")

    case target && resolve_resume_role(target, roles) do
      nil -> resolve_developer_role(roles)
      role -> role
    end
  end

  def resume_role_for_recovery(mode, _cycle_state, roles) when mode in [:advanced, :operator] do
    resolve_developer_role(roles)
  end

  # The stack's developer role — always present in both role sequences
  # (`developer-phoenix-backend` or `developer-static`).
  @spec resolve_developer_role([String.t()]) :: String.t()
  defp resolve_developer_role(roles) do
    Enum.find(roles, &String.starts_with?(&1, "developer-")) ||
      raise "OrchestrationLoop: no developer-* role in #{inspect(roles)}"
  end

  # Determines whether `cwd` carries a valid resume checkpoint: a durable,
  # gate-clear, tree-matched record of a prior cycle that died AFTER the
  # gate went green but BEFORE the commit step landed. See pitch "no
  # whole-build restart when the loop dies mid-cycle" for the full
  # discipline this encodes.
  #
  # Returns `{:resume, resume_role, state}` only when EVERY one of these
  # holds; any single failure (including the shell readers raising on an
  # absent gate-result.json, which `read_verdict/1` does by design) falls
  # through to `:full` — a checkpoint must never be guessed at:
  #
  #   * cycle-state.json exists and its state is GATED, REVIEWED, or CURATED
  #     (past-gate, pre-COMMITTED — COMMITTED/absent/unknown -> :full);
  #   * the checkpoint's stamped slug equals THIS cycle's slug (opts[:slug])
  #     — an empty stamp (pre-upgrade record, or a checkpoint written without
  #     a slug) or a foreign slug both refuse the resume. This is the
  #     identity guard: without it, a checkpoint left by pitch A is
  #     indistinguishable from one left by pitch B, and a later cycle for B
  #     can silently "resume" A's corpse (see pitch "a failed cycle leaves no
  #     checkpoint the NEXT pitch can resume into"). Checked FIRST among the
  #     guards below it depends on, but after the state-shape checks above
  #     it, since an absent/malformed record has no slug to compare anyway;
  #   * the last gate run's verdict is :clear;
  #   * the tree right now is byte-identical to what the gate graded
  #     (graded_tree_sha_now == gate_result_graded_tree_sha, both non-empty);
  #   * the matched tree still contains publishable working-tree changes — a
  #     clean checkpoint cannot be reviewed or committed and must restart;
  #   * HEAD has not moved since the gate ran (current HEAD starts with
  #     gate-result.json's base_sha) — rules out the rare "committer
  #     committed then died before advancing state to COMMITTED" edge;
  #   * the mapped resume role is actually present in `roles` for this stack.
  @doc false
  @spec resume_checkpoint(String.t(), [String.t()], run_opts()) ::
          {:resume, String.t(), String.t()} | :full
  def resume_checkpoint(cwd, roles, opts) do
    state_fn = Keyword.get(opts, :cycle_state_get_fn, &default_cycle_state_get/1)

    with state when is_binary(state) and state != "" <- state_fn.(cwd),
         target when is_binary(target) <- resume_role_for_state(state),
         resume_role when is_binary(resume_role) <- resolve_resume_role(target, roles),
         true <- resume_slug_match?(cwd, opts),
         :clear <- safe_read_verdict(cwd, opts),
         true <- gate_tree_match?(cwd, opts),
         true <- resume_work_present?(cwd, opts),
         true <- resume_head_unmoved?(cwd, opts) do
      {:resume, resume_role, state}
    else
      _ -> :full
    end
  end

  # A gate/tree match proves only that the checkpoint is internally
  # consistent. It does not prove there is still work to publish: a gate can
  # legitimately grade a clean tree (for example after another recovery
  # already landed the intended bytes). Resuming that checkpoint at reviewer
  # produces an empty review set; resuming at the commit step produces a
  # no-op. Both are deterministic failures, so reject the resume before
  # either is invoked. Non-git test/synthetic cwd values retain the
  # historical fail-open behavior; production cycles always run in a git
  # work tree.
  defp resume_work_present?(cwd, opts) do
    work_present_fn =
      Keyword.get(opts, :resume_work_present_fn, &default_resume_work_present?/1)

    work_present_fn.(cwd)
  end

  defp default_resume_work_present?(cwd) do
    if git_work_tree?(cwd) do
      case System.cmd("git", ["status", "--porcelain", "--untracked-files=all"],
             cd: cwd,
             stderr_to_stdout: true
           ) do
        {output, 0} -> String.trim(output) != ""
        _ -> false
      end
    else
      true
    end
  end

  # A checkpoint is resumable only by the cycle that wrote it. `opts[:slug]`
  # is the CURRENT cycle's slug (nil when the caller never passed one — a
  # nil/absent slug can never match a stamped checkpoint, so it correctly
  # refuses too). The stamped slug is read via :cycle_state_slug_fn — an
  # empty stamp (checkpoint predates this guard, or was written with no
  # slug) never matches, fail-closed by construction.
  @spec resume_slug_match?(String.t(), run_opts()) :: boolean()
  defp resume_slug_match?(cwd, opts) do
    slug_fn = Keyword.get(opts, :cycle_state_slug_fn, &default_cycle_state_slug/1)
    current_slug = Keyword.get(opts, :slug)
    stamped_slug = slug_fn.(cwd)

    is_binary(current_slug) and current_slug != "" and
      is_binary(stamped_slug) and stamped_slug != "" and
      current_slug == stamped_slug
  end

  defp default_cycle_state_slug(cwd) do
    unless File.exists?(@cycle_state_lib) do
      raise "OrchestrationLoop: cycle-state.sh not found at #{@cycle_state_lib}"
    end

    script =
      "source #{shell_quote(@cycle_state_lib)} && cycle_state_slug #{shell_quote(cwd)}"

    case System.cmd("bash", ["-c", script], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _code} -> ""
    end
  end

  # `LoopGate.read_verdict/1` RAISES when gate-result.json is absent or its
  # verdict field is missing/unrecognized (by design — the loop must never
  # silently treat a missing verdict as clear). A resume checkpoint that
  # never had a gate run is a completely normal, common case (most builds
  # die before the gate, or never die at all) — not an error here, just
  # "no checkpoint". Rescue converts that raise into the same :full-routing
  # non-match every other invalidation path already produces.
  @spec safe_read_verdict(String.t(), run_opts()) :: :clear | :failed | :error
  defp safe_read_verdict(cwd, opts) do
    verdict_fn = Keyword.get(opts, :read_verdict_fn, &LoopGate.read_verdict/1)
    verdict_fn.(cwd)
  rescue
    _ -> :error
  end

  defp default_cycle_state_get(cwd) do
    unless File.exists?(@cycle_state_lib) do
      raise "OrchestrationLoop: cycle-state.sh not found at #{@cycle_state_lib}"
    end

    script =
      "source #{shell_quote(@cycle_state_lib)} && cycle_state_get #{shell_quote(cwd)}"

    case System.cmd("bash", ["-c", script], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _code} -> ""
    end
  end

  @spec resume_head_unmoved?(String.t(), run_opts()) :: boolean()
  defp resume_head_unmoved?(cwd, opts) do
    base_sha_fn = Keyword.get(opts, :gate_result_base_sha_fn, &LoopGate.gate_result_base_sha/1)
    base_sha = base_sha_fn.(cwd)
    head = cycle_base_head(cwd)

    is_binary(base_sha) and base_sha != "" and is_binary(head) and
      String.starts_with?(head, base_sha)
  end

  # Drops the completed prefix of `roles`, returning the tail starting at
  # (and including) `resume_role`. `resume_role` is always a member of
  # `roles` here — resume_checkpoint/3 only returns a resume_role it found
  # via resolve_resume_role/2, which searches `roles` itself.
  #
  # `@commit_step_sentinel` resolves directly to `[]` — it is never a member
  # of `roles`, and `run_roles([], ...)` already runs the commit step
  # unconditionally as its terminal `[]` clause.
  @spec resume_suffix([String.t()], String.t()) :: [String.t()]
  defp resume_suffix(_roles, @commit_step_sentinel), do: []

  defp resume_suffix(roles, resume_role) do
    Enum.drop_while(roles, &(&1 != resume_role))
  end

  # Observability for a resumed cycle: one stderr line (always, names the
  # slug so the identity guard's decision is operator-visible) + one
  # best-effort cycle-log line appended under `resume_role` itself —
  # `resume_role` is always a real role from codegen-log's vocabulary
  # (loop/developer-*/reviewer-*/context-curator — see
  # shared/rules/_core/session-log.md § Event Schema), EXCEPT
  # `@commit_step_sentinel`, which `default_log_resume/2` maps to `"loop"`
  # (the commit step is loop-authored, not role-authored — see pitch
  # "committing is deterministic, not a model call") before ever shelling
  # `codegen-log`, so the resume note belongs to the section it resumes
  # into rather than an invented pseudo-role codegen-log would refuse.
  # Fail-loud-non-blocking: a codegen-log failure here must never abort a
  # resume that is otherwise valid.
  @spec log_resume(String.t(), String.t(), run_opts()) :: :ok
  defp log_resume(resume_role, state, opts) do
    slug = Keyword.get(opts, :slug)

    IO.puts(
      :stderr,
      "codegen.loop: resuming at #{display_resume_role(resume_role)} (prior state #{state}, " <>
        "gate clear, tree matched, slug #{slug}) — skipping the completed prefix"
    )

    log_resume_fn = Keyword.get(opts, :log_resume_fn, &default_log_resume/2)
    log_resume_fn.(resume_role, state)
  end

  defp default_log_resume(@commit_step_sentinel, state), do: default_log_resume("loop", state)

  defp default_log_resume(resume_role, state) do
    cycle_log = Process.get(@log_path_key)

    if is_nil(cycle_log) or not File.exists?(@codegen_log_bin) do
      :ok
    else
      body =
        "Resumed at #{resume_role} — prior cycle reached state #{state} with a clear gate " <>
          "on a matching tree; completed prefix skipped."

      {output, exit_code} =
        System.cmd(@codegen_log_bin, ["append", resume_role, "--body", body],
          stderr_to_stdout: true,
          env: [{"CODEGEN_DIR", @codegen_dir}, {"CODEGEN_LOG_PATH", cycle_log}]
        )

      if exit_code != 0 do
        IO.puts(
          :stderr,
          "OrchestrationLoop: codegen-log append (resume) failed (#{exit_code}): #{output}"
        )
      end

      :ok
    end
  end

  # Turn-0 typed scope event. The LOOP — not a role — authors this cycle's
  # `{"ev":"files_to_touch","role":"loop","files":[...]}` record, straight from
  # the pitch's mandatory `scope:` frontmatter list (parsed once, in
  # `Mix.Tasks.Codegen.Loop.resolve_pitch_scope!/2`, and threaded in as
  # `ctx.pitch_scope`). This event is what grants the developer its
  # `context/*.md` Reads: `subagent-read-discipline.sh` reads the field from
  # its AUTHOR's event, never from the calling role's own, and the author is
  # now a party that cannot be talked into widening its own grant.
  #
  # Nothing is written when the cycle has no log of its own (unit tests pass a
  # nil slug) or the pitch declared no scope (an ad-hoc literal pitch). An
  # absent event denies every `context/*.md` Read, which is the correct
  # posture for a pitch that promised nothing.
  #
  # Fail-loud-non-blocking, matching `default_log_resume/2`: a codegen-log
  # failure is reported on stderr and never aborts an otherwise valid cycle —
  # the consequence is a narrower read surface, not a wrong one.
  defp log_declared_scope(ctx, cwd, opts) do
    log_scope_fn = Keyword.get(opts, :log_scope_fn, &default_log_declared_scope/2)
    log_scope_fn.(Map.get(ctx, :pitch_scope), cwd)
  end

  defp default_log_declared_scope(scope, cwd) do
    cycle_log = Process.get(@log_path_key)

    cond do
      is_nil(cycle_log) -> :ok
      not is_list(scope) or scope == [] -> :ok
      not File.exists?(@codegen_log_bin) -> :ok
      true -> write_declared_scope_event(scope, cwd, cycle_log)
    end
  end

  defp write_declared_scope_event(scope, cwd, cycle_log) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "codegen-loop-scope-#{System.unique_integer([:positive])}.json"
      )

    File.write!(tmp, Jason.encode!(scope))

    # `cd:` only when the cwd really exists — the synthetic "/tmp/irrelevant"
    # cwd many unit tests pass would make System.cmd/3 itself raise, and
    # codegen-log resolves the target log from the absolute CODEGEN_LOG_PATH
    # rather than from its working directory anyway.
    cmd_opts = [
      stderr_to_stdout: true,
      env: [{"CODEGEN_DIR", @codegen_dir}, {"CODEGEN_LOG_PATH", cycle_log}]
    ]

    cmd_opts = if File.dir?(cwd), do: Keyword.put(cmd_opts, :cd, cwd), else: cmd_opts

    try do
      {output, exit_code} =
        System.cmd(@codegen_log_bin, ["append", "loop", "--files-to-touch", "@" <> tmp], cmd_opts)

      if exit_code != 0 do
        IO.puts(
          :stderr,
          "OrchestrationLoop: codegen-log append loop --files-to-touch failed " <>
            "(#{exit_code}): #{output}"
        )
      end
    after
      File.rm(tmp)
    end

    :ok
  end

  # Turn-0 HEAD guard, symmetric to verify_committed!/2's tail guard below.
  # Reuses the exact same porcelain + fail-exempt idiom: a non-existent cwd or
  # non-git work tree is a legitimate "nothing to verify" (only mocked tests
  # use such a cwd; real runs always operate in the scaffolded project's git
  # repo). A real dirty tree at cycle start raises — the loop is a pure
  # detector, never an auto-stasher; the operator (or the queue drainer's
  # existing stash-retry) resolves it.
  defp preflight_clean_tree!(cwd) do
    with true <- File.dir?(cwd),
         {out, 0} <-
           System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true) do
      dirty = String.trim(out)

      if dirty != "" do
        n = dirty |> String.split("\n") |> length()

        raise "OrchestrationLoop: the working tree is NOT clean before the cycle — " <>
                "#{n} uncommitted file(s):\n#{dirty}\n" <>
                "Commit or stash before starting a loop cycle; a cycle must begin from a " <>
                "clean tree so no role inherits or commits foreign changes."
      end

      :ok
    else
      # fail-loud-exempt: a non-existent cwd or non-git work tree is a
      # legitimate "nothing to verify" (only mocked tests use such a cwd).
      _ -> :ok
    end
  end

  # Structural gap #9 (verification): after the committer role runs, the working
  # tree MUST be clean — every cycle change committed. A dirty tree means the
  # committer did not actually commit (it no-op'd on an already-implemented
  # feature, hit a blocked git op, etc.). Fail loud rather than reporting a
  # false `loop_committed`. Gitignored paths never show in --porcelain, so a
  # legitimately-clean tree passes.
  defp verify_committed!(cwd, base_head) do
    # Only a real git work tree can be verified. Mocked tests pass a synthetic
    # cwd ("/tmp/irrelevant") that either does not exist or is not a repo; there
    # is nothing to verify there. A real loop run ALWAYS operates inside the
    # scaffolded project's git repo, so the guard always fires in production.
    with true <- File.dir?(cwd),
         {out, 0} <-
           System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true) do
      dirty = String.trim(out)

      if dirty != "" do
        n = dirty |> String.split("\n") |> length()

        raise "OrchestrationLoop: committer returned success but the working tree is NOT clean — " <>
                "#{n} uncommitted file(s):\n#{dirty}\n" <>
                "The committer must stage ALL cycle changes and create exactly one commit. " <>
                "Advancing COMMITTED here would be a false success (the failure the loop exists to prevent)."
      end

      assert_work_produced!(cwd, base_head)
      :ok
    else
      # fail-loud-exempt: a non-existent cwd or non-git work tree is a legitimate
      # "nothing to verify" (only mocked tests use such a cwd; real runs always
      # operate in the project git repo). The clean-tree assertion above is the
      # real guard and only applies when a git tree actually exists.
      _ -> :ok
    end
  end

  # Work-produced guard (FIX-4): a CLEAN tree alone does not prove the cycle
  # implemented anything — an empty/pristine tree is clean too. Require HEAD to
  # have advanced past the cycle base AND a non-empty diff base..HEAD. Empty →
  # raise → loop_failed, never a false loop_committed. base_head == nil means
  # we could not capture a base (non-git/unborn cwd — only mocked/edge cases);
  # skip the check there (nothing to compare), the clean-tree assertion above
  # is the guard.
  defp assert_work_produced!(_cwd, nil), do: :ok

  defp assert_work_produced!(cwd, base_head) do
    {count_out, 0} =
      System.cmd("git", ["rev-list", "--count", "#{base_head}..HEAD"],
        cd: cwd,
        stderr_to_stdout: true
      )

    commit_count = String.trim(count_out)
    exactly_one_commit? = commit_count == "1"

    {diff_out, 0} =
      System.cmd("git", ["diff", base_head, "HEAD"], cd: cwd, stderr_to_stdout: true)

    diff_nonempty? = String.trim(diff_out) != ""

    unless exactly_one_commit? and diff_nonempty? do
      raise "OrchestrationLoop: committer returned success but the cycle did NOT produce exactly one " <>
              "commit — git rev-list --count #{base_head}..HEAD = #{commit_count} (expected 1). " <>
              "0 = no-op false-success (no work committed); ≥2 = split commits (the invariant is ALL " <>
              "cycle changes in ONE commit). This is the no-op false-success the loop exists to prevent (loop_failed)."
    end

    assert_base_not_orphaned!(cwd, base_head)
    assert_commit_matches_gate!(cwd)
    assert_whole_pitch!(cwd, base_head)
    assert_test_coverage_floor!(cwd, base_head)

    :ok
  end

  # Whole-pitch completeness backstop (fail-closed, pre-commit): a cycle
  # diff that lands a defer-marker or a born-dead new entity (no live
  # non-test caller, no registration) is a FAILED build regardless of the
  # gate/commit shape being otherwise clean — see
  # `CodegenTestHarness.BornDeadDetector` moduledoc for the full contract.
  # This is the un-talk-around-able code guarantee behind "a build
  # implements the WHOLE pitch" (reviewer.md § Deliverable coverage and
  # § No Born-Dead / Deferred Work); the drain twin
  # (`LoopQueueDrain`'s `:born_dead_fn` seam) enforces the identical check
  # on its own independent ship floor — both must move together or a
  # drained build can bypass this raise.
  defp assert_whole_pitch!(cwd, base_head) do
    case BornDeadDetector.check(cwd, base_head) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "OrchestrationLoop: #{reason}. A build implements the WHOLE pitch — " <>
                "never a build-time slice, never deferred work. This is loop_failed, " <>
                "never a false loop_committed."
    end
  end

  # Test-coverage-floor backstop (fail-closed, pre-commit): a cycle diff
  # that DECREASES an existing test file's assertion-block count while its
  # subject module stays alive is a FAILED build — see
  # `CodegenTestHarness.TestCoverageFloor` moduledoc for the full contract
  # (the failure class `assert_whole_pitch!/2` above does not catch: a diff
  # can delete test coverage without introducing any new born-dead entity).
  # The drain twin (`LoopQueueDrain`'s `:coverage_floor_fn` seam) enforces
  # the identical check on its own independent ship floor — both must move
  # together or a drained build can bypass this raise.
  defp assert_test_coverage_floor!(cwd, base_head) do
    case TestCoverageFloor.check(cwd, base_head) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "OrchestrationLoop: #{reason}. This is loop_failed, never a false loop_committed."
    end
  end

  # Ancestry backstop (orphaned-base guard): the count+diff check above is
  # blind to a committer that ran `git reset <commit-ish> && git commit` —
  # such a reset moves HEAD *backward* past base_head, then a new commit is
  # made on top of the OLDER history. The new commit is still the sole commit
  # not reachable from base_head (count == 1) and the diff is still nonempty,
  # so the count+diff guard passes even though base_head's commit (and
  # everything after it, up to the reset target) has been dropped from the
  # branch. Assert base_head is still an ancestor of HEAD to catch this.
  defp assert_base_not_orphaned!(cwd, base_head) do
    case System.cmd("git", ["merge-base", "--is-ancestor", base_head, "HEAD"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {_out, _nonzero} ->
        raise "OrchestrationLoop: committer returned success but base commit #{base_head} is " <>
                "no longer an ancestor of HEAD — the cycle orphaned the base, most likely via a " <>
                "HEAD-moving `git reset` before the final commit. This silently drops a prior " <>
                "cycle's already-committed (possibly already-pushed) commit. Recover with: " <>
                "git rebase --onto #{base_head} <bad-commit>^ HEAD. This is loop_failed, never a " <>
                "false loop_committed."
    end
  end

  # No-ship-on-a-gate-that-didn't-grade-this-tree, post-commit half:
  # `ensure_gate_graded_this_tree!/4` re-gates BEFORE the committer runs, but
  # nothing yet proves the committer's ACTUAL commit is the tree that gate
  # graded — the committer runs as its own role invocation and could, in
  # principle, still diverge (an edit, a partial-stage, a script it ran).
  # `git commit`'s own tree is exactly HEAD-plus-everything-staged, which for
  # a faithful committer (`git add -A && git commit`) is definitionally the
  # same computation `LoopGate.graded_tree_sha_now/1` performs at gate time —
  # so a match here is not an approximation, it is the same content by
  # construction. A mismatch means the committer's commit diverged from what
  # was last graded clear.
  #
  # `""` stamped graded_tree_sha (non-git cwd, or no gate ran in this
  # cycle's opts — e.g. most mocked unit tests) → skip, matching every
  # other sentinel-skip in `verify_committed!`'s guard chain.
  defp assert_commit_matches_gate!(cwd) do
    stamped = LoopGate.gate_result_graded_tree_sha(cwd)

    if stamped != "" do
      {commit_tree, 0} =
        System.cmd("git", ["rev-parse", "HEAD^{tree}"], cd: cwd, stderr_to_stdout: true)

      commit_tree = String.trim(commit_tree)

      unless commit_tree == stamped do
        raise "OrchestrationLoop: committed tree #{commit_tree} does not match the " <>
                "last graded_tree_sha #{stamped} — the commit landed on DIFFERENT content than " <>
                "the gate verdict describes. This is the exact false-success the pre-commit " <>
                "re-gate exists to prevent slipping through (loop_failed, never a false " <>
                "loop_committed)."
      end
    end

    :ok
  end

  # Reviewer→developer fix cycle (structural gap #7). The reviewer ends its output
  # with `REVIEW_VERDICT: APPROVED | CHANGES_REQUESTED` (instructed via build_prompt).
  # APPROVED → advance REVIEWED and continue. CHANGES_REQUESTED (within
  # :max_review_cycles, default 1) → re-invoke the developer with the reviewer's
  # feedback, re-format, re-gate, re-review, and recurse.
  #
  # `:unknown` here means `resolve_review/1` found no verdict in the returned
  # value AND could not recover one from the reviewer's own transcript
  # (truncated response, crash mid-sentence, refusal, or simply never stated
  # one). It is NEVER folded into the same "proceed" arm as
  # `:approved` — that used to silently ship an unreviewed change (a
  # reviewer that fails to emit its verdict is not the same thing as a
  # reviewer that approved). One re-invocation is granted, explicitly
  # demanding the sentinel; a SECOND unparseable result raises loud rather
  # than advancing — this is a re-work bounded exactly like
  # `run_curator_doc_check`'s own budget-exhaustion posture (fail loud, not
  # proceed), not `:changes_requested`'s.
  #
  # Budget-exhausted `:changes_requested` (cycle >= max_cycles) is aligned
  # to the SAME fail-loud posture — a review that still requested changes
  # when the retry budget ran out is not the same thing as an approval
  # either, and silently proceeding used to treat the two identically.
  #
  # Coverage is checked BEFORE the verdict is parsed at all (pitch "review
  # verdicts name the surface they read") — an APPROVED (or
  # CHANGES_REQUESTED) that does not name what it read is not yet a
  # reviewed result.
  #
  # THREE budgets, deliberately separate, because they buy different things
  # and a RESTATEMENT must never cost a REWORK:
  #
  #   * `cycle` / `:max_review_cycles` (default 3) — real rework. The
  #     reviewer read the code and wants it changed; a developer runs, the
  #     tree changes, the gate re-runs. Expensive, and the only one of the
  #     three that makes progress on the code.
  #   * `coverage_cycle` / `:max_review_coverage_cycles` (default 2) — the
  #     reviewer did not name the surface it read. No code changes.
  #   * `verdict_cycle` / `:max_review_verdict_cycles` (default 1) — the
  #     reviewer stated no parseable verdict. No code changes.
  #
  # Both restatement budgets used to be, or still were, entangled with the
  # rework budget: an `:unknown` verdict incremented `cycle`, so ONE
  # formatting slip silently spent a rework the reviewer had actually asked
  # for. They are now independent, which is also what makes it safe to raise
  # `:max_review_cycles` — raising a shared counter would have tripled the
  # far more expensive re-ask budgets along with it.
  #
  # Termination: `verdict_cycle` resets `coverage_cycle` (an :unknown re-ask
  # hands back a wholly NEW review, whose coverage must be re-checked from
  # scratch) but a coverage re-ask does NOT reset `verdict_cycle`. That
  # asymmetry is what forbids a coverage/verdict ping-pong: the pair is
  # bounded at `max_verdict_cycles * (max_coverage_cycles + 1)` re-asks. A
  # rework resets both, and is itself bounded by `max_cycles`.
  defp handle_review(reviewer_role, review_result, rest, harness, ctx, opts, cycle) do
    handle_review(reviewer_role, review_result, rest, harness, ctx, opts, cycle, 0, 0)
  end

  defp handle_review(
         reviewer_role,
         review_result,
         rest,
         harness,
         ctx,
         opts,
         cycle,
         coverage_cycle,
         verdict_cycle
       ) do
    max_coverage_cycles = Keyword.get(opts, :max_review_coverage_cycles, 2)
    expected_files = get_in(ctx, [:artifacts, :review_file_set]) || ""

    case parse_review_coverage(review_result, expected_files) do
      {:incomplete, reason} when coverage_cycle < max_coverage_cycles ->
        handle_incomplete_coverage(
          reviewer_role,
          rest,
          harness,
          ctx,
          opts,
          cycle,
          coverage_cycle,
          verdict_cycle,
          reason
        )

      {:incomplete, reason} ->
        {:error,
         "reviewer coverage did not name the ## Files Modified set after " <>
           "#{coverage_cycle + 1} attempt(s): #{reason}"}

      {:ok, _coverage} ->
        do_handle_review_verdict(
          reviewer_role,
          review_result,
          rest,
          harness,
          ctx,
          opts,
          cycle,
          verdict_cycle
        )
    end
  end

  # Coverage re-work path: re-invoke the SAME reviewer once (per
  # `:max_review_coverage_cycles`), explicitly naming the exact
  # missing/invented/malformed entries so the reviewer does not have to
  # re-derive what was wrong — no developer re-work, no gate re-run,
  # mirroring `handle_unparseable_review/6`'s reasoning: nothing about the
  # code changed, only the reviewer's statement of what it covered was
  # incomplete.
  defp handle_incomplete_coverage(
         reviewer_role,
         rest,
         harness,
         ctx,
         opts,
         cycle,
         coverage_cycle,
         verdict_cycle,
         reason
       ) do
    ctx =
      put_in(
        ctx,
        [:artifacts, :review_coverage_incomplete],
        coverage_contract_message(reason, ctx, opts, coverage_cycle)
      )

    with {:ok, review2} <- invoke_with_retry(reviewer_role, harness, ctx, opts) do
      ctx = put_in(ctx, [:artifacts, reviewer_role], review2)

      handle_review(
        reviewer_role,
        review2,
        rest,
        harness,
        ctx,
        opts,
        cycle,
        coverage_cycle + 1,
        verdict_cycle
      )
    end
  end

  # The re-ask prompt is the ONLY place the full coverage contract is stated,
  # and it is stated ONLY here. `parse_review_coverage/2` terminally fails a
  # build on six distinct rules; `shared/rules/roles/reviewer.md` names one of
  # them in one line. Restating the whole contract in the steady-state role
  # prompt would cost every reviewer invocation in every build those bytes,
  # forever, to prevent a failure most of them never hit. Stating it HERE
  # costs nothing until the contract is actually broken, and then states it
  # in full, with the reviewer's own specific gap quoted back — which is
  # strictly more teaching than a rule file can give, because a rule file
  # cannot name the paths this reviewer actually missed.
  defp coverage_contract_message(reason, ctx, opts, coverage_cycle) do
    expected = get_in(ctx, [:artifacts, :review_file_set]) || ""
    max_coverage_cycles = Keyword.get(opts, :max_review_coverage_cycles, 2)
    remaining = max_coverage_cycles - coverage_cycle

    expected_block =
      expected
      |> String.split("\n", trim: true)
      |> Enum.map_join("\n", &"  #{&1}")

    """
    Your previous response's REVIEW_COVERAGE: lines did not satisfy the coverage \
    contract, so this review was NOT accepted.

    What was wrong, specifically: #{reason}

    The full contract your next response must satisfy:

    1. EXACT LINE FORMAT. Each coverage line must match this regex anchored at \
    both ends: `^REVIEW_COVERAGE:[ \\t]*(?<path>\\S+)[ \\t]+(?<state>read|skipped:.*)$` \
    — i.e. literally `REVIEW_COVERAGE: <path> read` or \
    `REVIEW_COVERAGE: <path> skipped: <reason>`. The path may not contain \
    whitespace. A `skipped:` reason may not be empty. Surrounding `**`/`` ` ``/`_` \
    decoration is peeled, but nothing else is tolerated — no bullet prefix, no \
    trailing commentary on the line, no prose wrapper.
    2. TOTALITY. You must emit one line for EVERY path in the ## Files Modified \
    set below — no more, no fewer. This is checked against the set the LOOP \
    computed from git, not against what you chose to read.
    3. NO INVENTED PATHS. Naming a path that is NOT in that set fails the build \
    just as hard as omitting one. Do not normalise, abbreviate, or re-spell the \
    paths — copy them exactly as listed.
    4. `skipped:` IS ALLOWED. Skipping a file is a legitimate, non-blocking \
    answer; leaving it unstated is not. If you did not read it, say \
    `skipped: <why>` rather than omitting the line.
    5. COVERAGE IS CHECKED BEFORE YOUR VERDICT IS READ AT ALL. An APPROVED that \
    does not name its surface is not a reviewed result, and your verdict will \
    not even be parsed until these lines are complete.
    6. RETRY BUDGET. #{remaining} attempt(s) remain (`:max_review_coverage_cycles`). \
    When it is exhausted the build FAILS — it does not proceed as approved.

    The exact ## Files Modified set you must cover (#{length(String.split(expected, "\n", trim: true))} path(s)):
    #{expected_block}

    Emit these lines BEFORE your REVIEW_VERDICT: line, then restate that verdict.
    """
  end

  defp do_handle_review_verdict(
         reviewer_role,
         review_result,
         rest,
         harness,
         ctx,
         opts,
         cycle,
         verdict_cycle
       ) do
    max_cycles = Keyword.get(opts, :max_review_cycles, 3)
    max_verdict_cycles = Keyword.get(opts, :max_review_verdict_cycles, 1)
    {_verdict, review_result} = resolve_review(review_result)

    case classify_verdict_severity(review_result) do
      :changes_requested when cycle < max_cycles ->
        # A resumed GATED cycle has only :resume_state in artifacts. Resolve
        # from the configured stack so its blocking review reaches the
        # developer that can actually repair it.
        dev_role = resolve_developer_role(role_sequence(Keyword.fetch!(opts, :stack)))
        feedback = review_result["value"] || "changes requested"
        brief = capture_rework_brief(ctx.cwd, opts)

        rework_ctx =
          ctx
          |> put_in([:artifacts, :review_feedback], feedback)
          |> put_in([:artifacts, :rework_brief], brief)

        with {:ok, dev_result} <- invoke_with_retry(dev_role, harness, rework_ctx, opts) do
          ctx = put_in(rework_ctx, [:artifacts, dev_role], dev_result)
          run_format_step(ctx.cwd, opts)

          case run_gate_once(ctx, opts) do
            :clear ->
              advance_cycle_state_step("GATED", ctx, opts)
              review_final_attempt? = cycle + 1 >= max_cycles

              ctx =
                ctx
                |> put_in([:artifacts, :review_pass_number], cycle + 2)
                |> put_in([:artifacts, :review_max_passes], max_cycles + 1)
                |> maybe_escalate_model(reviewer_role, harness, opts, review_final_attempt?)
                |> maybe_advise(reviewer_role, harness, opts, review_final_attempt?, %{
                  stage: "review_rework",
                  attempt: cycle + 1,
                  ceiling: max_cycles
                })

              with {:ok, review2, ctx} <- invoke_reviewer(reviewer_role, harness, ctx, opts) do
                ctx =
                  ctx
                  |> put_in([:artifacts, reviewer_role], review2)
                  |> update_in([:artifacts], &Map.delete(&1, :escalated_model))
                  |> update_in([:artifacts], &Map.delete(&1, :advisor_plan))

                handle_review(reviewer_role, review2, rest, harness, ctx, opts, cycle + 1)
              end

            verdict ->
              {:error, "gate verdict=#{verdict} after review re-work (cycle #{cycle + 1})"}
          end
        end

      :changes_requested ->
        # Budget exhausted — do NOT silently proceed as if approved.
        {:error,
         "reviewer requested changes and the review re-work budget (#{max_cycles}) is " <>
           "exhausted: #{review_result["value"] || "changes requested"}"}

      :approved ->
        advance_cycle_state_step("REVIEWED", ctx, opts)
        run_roles(rest, harness, ctx, opts)

      :approved_with_findings ->
        # Every finding explicitly opted into the Non-blocking convention.
        # Preserve it for the post-review curator rather than dropping it.
        ctx =
          put_in(ctx, [:artifacts, :review_non_blocking_findings], review_result["value"] || "")

        advance_cycle_state_step("REVIEWED", ctx, opts)
        run_roles(rest, harness, ctx, opts)

      :unknown when verdict_cycle < max_verdict_cycles ->
        handle_unparseable_review(
          reviewer_role,
          rest,
          harness,
          ctx,
          opts,
          cycle,
          verdict_cycle,
          review_result["value"]
        )

      :unknown ->
        {:error,
         "reviewer output carried no parseable REVIEW_VERDICT: sentinel after " <>
           "#{verdict_cycle + 1} attempt(s) — refusing to silently advance as approved. " <>
           "Last output: #{inspect(review_result["value"])}"}
    end
  end

  # `:unknown` re-work path: re-invoke the SAME reviewer once, explicitly
  # demanding the missing sentinel — no developer re-work, no gate re-run,
  # since nothing about the code changed; only the reviewer failed to state
  # its verdict. A second `:unknown` raises (see `handle_review/7`'s
  # `:unknown` catch-all) rather than looping indefinitely.
  defp handle_unparseable_review(
         reviewer_role,
         rest,
         harness,
         ctx,
         opts,
         cycle,
         verdict_cycle,
         last_output
       ) do
    ctx =
      put_in(
        ctx,
        [:artifacts, :review_verdict_missing],
        verdict_contract_message(last_output, opts, verdict_cycle)
      )

    with {:ok, review2} <- invoke_with_retry(reviewer_role, harness, ctx, opts) do
      ctx = put_in(ctx, [:artifacts, reviewer_role], review2)

      # `cycle` is NOT incremented: a reviewer that failed to STATE a verdict
      # has not spent a rework the reviewer might still be about to ask for.
      # `coverage_cycle` resets — this is a wholly new review body.
      handle_review(reviewer_role, review2, rest, harness, ctx, opts, cycle, 0, verdict_cycle + 1)
    end
  end

  # Counterpart to `coverage_contract_message/4`, same reasoning: state the
  # whole verdict contract exactly when it has been broken, and nowhere else.
  # `parse_review_verdict/1` fails a build on rules the one-line instruction
  # in `shared/rules/roles/reviewer.md` does not mention at all — chiefly
  # UNANIMITY (the rule that actually bites, and the least guessable).
  defp verdict_contract_message(last, opts, verdict_cycle) do
    max_verdict_cycles = Keyword.get(opts, :max_review_verdict_cycles, 1)
    remaining = max_verdict_cycles - verdict_cycle

    """
    Your previous response carried no parseable REVIEW_VERDICT: verdict, so this \
    review was NOT accepted.#{if last, do: "\n\nWhat you returned: #{inspect(last)}", else: ""}

    The full contract your next response must satisfy:

    1. EXACT LINE FORMAT. Emit a line that is exactly `REVIEW_VERDICT: APPROVED` \
    or exactly `REVIEW_VERDICT: CHANGES_REQUESTED`. Those two are the ONLY \
    accepted values — `MAYBE`, `APPROVED_WITH_NITS`, lowercase `approved`, or \
    any other word fails.
    2. NOTHING ELSE ON THE LINE. Symmetric `**`, `` ` `` or `_` decoration is \
    peeled (so `**REVIEW_VERDICT: APPROVED**` is fine), but a trailing clause is \
    NOT: `REVIEW_VERDICT: APPROVED. Logged.` and \
    `✅ QUALITY APPROVED — REVIEW_VERDICT: APPROVED. Logged.` both fail. An \
    unbalanced delimiter (`` `REVIEW_VERDICT: APPROVED ``) also fails.
    3. UNANIMITY — the rule most often broken. EVERY line in your response that \
    contains the string `REVIEW_VERDICT:` is classified, wherever it sits, and \
    they must ALL agree. One well-formed verdict plus one earlier draft, \
    restatement, or discussion of the other verdict is AMBIGUOUS and fails \
    closed. Do not quote this contract back, do not narrate the verdict you \
    considered, do not restate the verdict "for the log" — mention the string \
    `REVIEW_VERDICT:` exactly once.
    4. PROSE MENTIONS COUNT AGAINST YOU. A hedged line like "I would have said \
    REVIEW_VERDICT: APPROVED but the gate is red" is not a verdict, and its \
    presence poisons an otherwise good verdict elsewhere in the body.
    5. PLACEMENT IS FREE. The verdict line does NOT have to be last. A findings \
    list or closing paragraph after it is fine. State it once, correctly, \
    anywhere.
    6. FAILING TO STATE ONE IS NOT AN APPROVAL. #{remaining} attempt(s) remain \
    (`:max_review_verdict_cycles`). When it is exhausted the build FAILS — it \
    never advances as approved.

    Re-state your review now, honouring all six.
    """
  end

  # Context-curator → curator-doc fix cycle (factcheck + index-parity).
  # Replaces the dead-under-loop `context-factcheck-curator-stop` SubagentStop
  # hook AND the commit-time `context-index-parity` hook: under the loop,
  # roles run as main-agent `codegen-call` invocations with no SubagentStop
  # event, so the factcheck backstop has to be driven explicitly here (same
  # reasoning as `run_format_step`); index-parity can NEVER be a per-edit gate
  # (an ADD needs BOTH the file AND its index row, so whichever write lands
  # first would deadlock a PreToolUse gate), so it is inherently an
  # end-of-turn check, and this step is its only home. Clean → advance
  # CURATED and continue. Violations within the `:max_curator_doc_cycles`
  # guaranteed floor (default 1), OR beyond it while the curator keeps
  # provably resolving violations (see `repair_allowed?/4`), → fold the
  # combined violation list into context, re-invoke the context-curator (the
  # last role that CAN edit `context/*.md`), re-format, re-scan, recurse.
  # Budget-exhausted → FAIL LOUD (same posture as `handle_review`'s own
  # budget exhaustion): the curator is the only role permitted to edit
  # these docs, so a violation it did not clear must never travel onward as
  # if it had been fixed. Retryable, never terminal-marked.
  defp run_curator_doc_check(
         curator_role,
         rest,
         harness,
         ctx,
         opts,
         cycle,
         prev_violations \\ nil
       ) do
    max_cycles = Keyword.get(opts, :max_curator_doc_cycles, 1)

    case run_curator_doc_scan(ctx.cwd, opts) do
      {:clean} ->
        advance_cycle_state_step("CURATED", ctx, opts)
        run_roles(rest, harness, ctx, opts)

      {:violations, violations} ->
        classify_fn = Keyword.get(opts, :text_classify_fn, &LoopGate.classify_failure/1)

        if classify_fn.(violations) == :infra do
          LoopGate.infra_abort!(
            "curator-doc-check",
            "unsatisfiable by any curator edit (classified :infra) — #{violations}"
          )
        else
          run_curator_doc_check_rework(
            curator_role,
            rest,
            harness,
            ctx,
            opts,
            cycle,
            max_cycles,
            violations,
            prev_violations
          )
        end
    end
  end

  # A curator edit CAN plausibly fix these doc violations — delegate to the
  # SHARED repair engine (`run_orientation_repair/1`), also used by the
  # turn-0 preflight (`run_orientation_preflight/4`). This phase's
  # continuations preserve exact pre-extraction behavior: clean advances
  # `CURATED` and continues into `rest`; exhaustion writes the terminal
  # marker and returns the "cycle-created violations" formatter. See
  # `run_curator_doc_check/6`'s `:infra` branch above for the sibling that
  # never reaches here.
  defp run_curator_doc_check_rework(
         curator_role,
         rest,
         harness,
         ctx,
         opts,
         cycle,
         max_cycles,
         violations,
         prev_violations
       ) do
    run_orientation_repair(%{
      phase: :post_curator,
      scan_fn: fn -> run_curator_doc_scan(ctx.cwd, opts) end,
      curator_role: curator_role,
      harness: harness,
      ctx: ctx,
      opts: opts,
      cycle: cycle,
      prev_violations: prev_violations,
      max_cycles: max_cycles,
      seed_violations: violations,
      on_clean: fn clean_ctx, _repair_ran? ->
        advance_cycle_state_step("CURATED", clean_ctx, opts)
        run_roles(rest, harness, clean_ctx, opts)
      end,
      on_failure: &curator_doc_check_exhausted/3
    })
  end

  # NO terminal marker here. A terminal marker is a claim that no retry can
  # ever succeed: `default_terminal_marker_fn/1` is read BEFORE
  # `retry_eligible?/5` and routes straight to park + skip + circuit breaker
  # (`context/loop-queue-drain.md` § Deterministic Failure), so a marked
  # cycle is NEVER retried. Orientation-doc drift does not earn that claim —
  # the curator writes `context/**`/`PROJECT_CONTEXT.md` freely, the scan is
  # deterministic over the tree, and a repeat pass on a re-primed curator
  # routinely lands what one bounded pass did not. The cycle still FAILS
  # (the `{:error, ...}` below is unchanged); it just stays retry-eligible
  # instead of parking the pitch and burning a slot on the breaker.
  # Contrast `:gate verdict=failed`, which keeps its marker: a red gate is a
  # real, reproduced defect in the tree, and re-paying for the same red is
  # exactly what the marker exists to stop.
  defp curator_doc_check_exhausted(ctx, cycle, violations) do
    {:error,
     "Turn-0 preflight found no inherited orientation-doc drift at HEAD #{ctx.base_head}; " <>
       "the violations below arrived with this cycle's own edits.\n" <>
       "context-curator doc check unresolved after #{cycle} cycle(s):\n#{violations}\n" <>
       "context-curator is the only role permitted to edit these docs, so a violation it did " <>
       "not clear must not travel onward as if it had been fixed. This cycle FAILED but is " <>
       "retry-eligible (no terminal marker) — re-run it, or fix the orientation docs directly."}
  end

  # Turn-0 phase exhaustion formatter — sibling of `curator_doc_check_exhausted/3`
  # above (post-curator phase). Distinguishes the two in the returned
  # message: this violation was ALREADY present at HEAD (inherited), not
  # introduced by this cycle's own edits.
  # Same reasoning as `curator_doc_check_exhausted/3` above: no terminal
  # marker. Inherited drift that one bounded repair pass did not clear is a
  # retryable cycle failure, not a permanent one.
  defp turn0_repair_exhausted(_ctx, cycle, violations) do
    {:error,
     "inherited orientation-doc repair remained unresolved after #{cycle} cycle(s):\n" <>
       "#{violations}\n" <>
       "context-curator could not repair this drift, which was already present at HEAD " <>
       "before this cycle started. Fix the orientation docs and re-run the cycle."}
  end

  # Shared repair engine serving BOTH the turn-0 preflight
  # (`run_orientation_preflight/4`) and the post-curator per-cycle doc check
  # (`run_curator_doc_check_rework/9`). Owns the floor/progress/ceiling
  # bound (`repair_allowed?/4`), the `:curator_doc_violations` prompt
  # artifact, the curator invocation, the post-turn format step, the
  # caller-supplied rescan, and the terminal-marker-on-exhaustion path. The
  # two phases differ ONLY in `:scan_fn` (which scan re-runs), `:on_clean`
  # (turn-0 never advances `CURATED`; post-curator does), and `:on_failure`
  # (phase-specific wording) — everything else is identical control flow.
  #
  # `opts[:max_cycles]` defaults to `Keyword.get(opts, :max_curator_doc_cycles, 1)`
  # when absent — the turn-0 caller never threads `:max_cycles` explicitly,
  # so it inherits the SAME floor the post-curator phase uses by default.
  # `opts[:seed_violations]`, when present, is the ALREADY-KNOWN violation
  # text for `cycle` (post-curator phase already has it from
  # `run_curator_doc_check/6`'s scan); turn-0 omits it and the engine
  # performs its own first scan via `scan_fn`.
  @spec run_orientation_repair(map()) :: map() | {:error, String.t()}
  defp run_orientation_repair(
         %{
           # `:phase` is intentionally unread here — both `:on_clean`/`:on_failure`
           # continuations already carry phase-specific behavior/wording, so this
           # engine has no separate branch on it. Kept in the map (never matched
           # away) purely as a required, self-documenting field at each call site.
           phase: _phase,
           scan_fn: scan_fn,
           curator_role: curator_role,
           harness: harness,
           ctx: ctx,
           opts: opts,
           cycle: cycle,
           prev_violations: prev_violations,
           on_clean: on_clean,
           on_failure: on_failure
         } = repair
       ) do
    max_cycles = Map.get(repair, :max_cycles, Keyword.get(opts, :max_curator_doc_cycles, 1))

    violations =
      case Map.get(repair, :seed_violations) do
        nil ->
          case scan_fn.() do
            {:clean} -> nil
            {:violations, v} -> v
          end

        seed ->
          seed
      end

    case violations do
      nil ->
        on_clean.(ctx, cycle > 0)

      violations ->
        if repair_allowed?(cycle, max_cycles, prev_violations, violations) do
          rework_ctx = put_in(ctx, [:artifacts, :curator_doc_violations], violations)

          with {:ok, curator_result} <- invoke_with_retry(curator_role, harness, rework_ctx, opts) do
            ctx = put_in(rework_ctx, [:artifacts, curator_role], curator_result)
            run_format_step(ctx.cwd, opts)

            next_repair =
              repair
              |> Map.merge(%{ctx: ctx, cycle: cycle + 1, prev_violations: violations})
              |> Map.delete(:seed_violations)

            run_orientation_repair(next_repair)
          end
        else
          on_failure.(ctx, cycle, violations)
        end
    end
  end

  # Dispatches the `:curator_doc_check_fn` test seam; defaults to a closure
  # over `default_curator_doc_scan/2` capturing `gate_opts(opts)` (for
  # `:cycle_log` — `opts` alone does NOT carry it; this step runs from
  # `run_roles/4`, upstream of `run_gate_once/2`'s own `gate_opts/1` call, so
  # this is the first point in the curator-doc path that needs the log path
  # and must resolve it itself, same as `run_gate_once/2` does) — the seam
  # itself stays arity-1 so the 30+ existing test overrides
  # (`(cwd -> {:clean} | {:violations, _}}`) are untouched.
  defp run_curator_doc_scan(cwd, opts) do
    scan_fn =
      Keyword.get(opts, :curator_doc_check_fn, fn c ->
        default_curator_doc_scan(c, gate_opts(opts))
      end)

    scan_fn.(cwd)
  end

  # Runs index-parity (cross-file, working-tree-vs-HEAD) AND the factcheck
  # Bash-write backstop (diff-scoped to this cycle's own orientation-doc
  # edits), joining any violations from either into one message.
  #
  # Index-parity: shells `context-index-parity-scan.sh <cwd>` unconditionally
  # (cheap — a single git diff/ls-files call) — detects a working-tree
  # `context/*.md` add/delete lacking `PROJECT_CONTEXT.md` § Domain Context
  # Files parity. exit 0 → clean; exit 1 with output → violations; anything
  # else is an infra fault — raise (fail-closed).
  #
  # Factcheck backstop: diff-scopes to the CURRENT CYCLE's own
  # orientation-doc edits via `changed_orientation_docs/1` — ambient rot in a
  # doc this cycle never touched must not block an unrelated build. Empty
  # list → skip the shell-out entirely (nothing this cycle could have
  # broken); this catches a Bash `sed`/`printf>`/`mv` write to a changed doc
  # that the PreToolUse `context-factcheck-edit-gate` hook (Edit/Write/
  # MultiEdit only) never saw. Non-empty list → shells
  # `context-factcheck-scan.sh <cwd> <doc>...` scoped to exactly those docs.
  # exit 0 → clean; exit 1 with output → violations; anything else is an
  # infra fault — raise (fail-closed).
  defp default_curator_doc_scan(cwd, opts) do
    unless File.exists?(@index_parity_scan_lib) do
      raise "OrchestrationLoop: context-index-parity-scan.sh not found at #{@index_parity_scan_lib}"
    end

    unless File.exists?(@factcheck_scan_lib) do
      raise "OrchestrationLoop: context-factcheck-scan.sh not found at #{@factcheck_scan_lib}"
    end

    unless File.exists?(@consumption_scan_lib) do
      raise "OrchestrationLoop: curator-consumption-scan.sh not found at #{@consumption_scan_lib}"
    end

    index_parity_result =
      case System.cmd("bash", [@index_parity_scan_lib, cwd], stderr_to_stdout: true) do
        {_out, 0} ->
          {:clean}

        {out, 1} ->
          {:violations, String.trim(out)}

        {out, code} ->
          raise "OrchestrationLoop: context-index-parity-scan.sh exited #{code} (expected 0 or 1): #{out}"
      end

    factcheck_result =
      case changed_orientation_docs(cwd) do
        [] ->
          {:clean}

        changed_docs ->
          case System.cmd("bash", [@factcheck_scan_lib, cwd | changed_docs],
                 stderr_to_stdout: true
               ) do
            {_out, 0} ->
              {:clean}

            {out, 1} ->
              {:violations, String.trim(out)}

            {out, code} ->
              raise "OrchestrationLoop: context-factcheck-scan.sh exited #{code} (expected 0 or 1): #{out}"
          end
      end

    consumption_result =
      case Keyword.get(opts, :cycle_log) do
        nil ->
          {:clean}

        cycle_log ->
          case System.cmd("bash", [@consumption_scan_lib, cwd, cycle_log], stderr_to_stdout: true) do
            {_out, 0} ->
              {:clean}

            {out, 1} ->
              {:violations, String.trim(out)}

            {out, code} ->
              raise "OrchestrationLoop: curator-consumption-scan.sh exited #{code} (expected 0 or 1): #{out}"
          end
      end

    index_parity_result
    |> combine_curator_doc_results(factcheck_result)
    |> combine_curator_doc_results(consumption_result)
  end

  defp combine_curator_doc_results({:clean}, {:clean}), do: {:clean}

  defp combine_curator_doc_results({:violations, v}, {:clean}), do: {:violations, v}

  defp combine_curator_doc_results({:clean}, {:violations, v}), do: {:violations, v}

  defp combine_curator_doc_results({:violations, v1}, {:violations, v2}) do
    {:violations, Enum.join([v1, v2], "\n")}
  end

  # Developer → env-var sample-consistency fix cycle. Replaces the
  # dead-under-loop `env-var-sample-consistency` SubagentStop hook: under
  # the loop, roles run as main-agent `codegen-call` invocations with no
  # SubagentStop event, so this scan has to be driven explicitly here (same
  # reasoning as `run_format_step` and `run_curator_doc_check`). Scan clean →
  # continue to the gate. Violations within the `:max_env_var_cycles`
  # guaranteed floor (default 1), OR beyond it while the developer keeps
  # provably resolving violations (see `repair_allowed?/4`), → fold the
  # undocumented-var list into context, re-invoke the SAME developer role
  # (the one that can edit `.env.sample`/`.env.prod.sample`), re-format,
  # re-scan, recurse. Budget-exhausted → FAIL LOUD (same posture
  # as `run_curator_doc_check` and `handle_review` — none of the three
  # budgets proceeds on exhaustion): an undeclared required env var is a
  # real defect the app crashes on at runtime.
  defp run_env_var_step(dev_role, rest, harness, ctx, opts, cycle, prev_violations \\ nil) do
    max_cycles = Keyword.get(opts, :max_env_var_cycles, 1)

    case run_env_var_scan(ctx.cwd, opts) do
      {:clean} ->
        run_gate_then_continue(dev_role, rest, harness, ctx, opts)

      {:violations, violations} ->
        classify_fn = Keyword.get(opts, :text_classify_fn, &LoopGate.classify_failure/1)

        if classify_fn.(violations) == :infra do
          LoopGate.infra_abort!(
            "env-var-sample-scan",
            "unsatisfiable by any developer edit (classified :infra) — #{violations}"
          )
        else
          run_env_var_step_rework(
            dev_role,
            rest,
            harness,
            ctx,
            opts,
            cycle,
            max_cycles,
            violations,
            prev_violations
          )
        end
    end
  end

  # A developer edit CAN plausibly fix these env-var violations — run the
  # progress+ceiling-bounded rework logic (see `repair_allowed?/4`): the
  # first rework (cycle < max_cycles, the guaranteed floor) is always
  # granted; beyond the floor, only when the developer provably resolved at
  # least one violation from the prior scan. See `run_env_var_step/6`'s
  # `:infra` branch above for the sibling that never reaches here.
  defp run_env_var_step_rework(
         dev_role,
         rest,
         harness,
         ctx,
         opts,
         cycle,
         max_cycles,
         violations,
         prev_violations
       ) do
    if repair_allowed?(cycle, max_cycles, prev_violations, violations) do
      brief = capture_rework_brief(ctx.cwd, opts)

      rework_ctx =
        ctx
        |> put_in([:artifacts, :env_var_violation], violations)
        |> put_in([:artifacts, :rework_brief], brief)

      with {:ok, dev_result} <- invoke_with_retry(dev_role, harness, rework_ctx, opts) do
        ctx = put_in(rework_ctx, [:artifacts, dev_role], dev_result)
        run_format_step(ctx.cwd, opts)
        run_env_var_step(dev_role, rest, harness, ctx, opts, cycle + 1, violations)
      end
    else
      write_terminal_marker(ctx.cwd, "env var sample-consistency unresolved", dev_role)

      {:error,
       "env var sample-consistency unresolved after #{cycle} cycle(s):\n#{violations}\n" <>
         "Undeclared env var(s) are read (System.get_env/fetch_env) but not declared in " <>
         ".env.sample and/or .env.prod.sample. Declare them in BOTH sample files and re-run " <>
         "the cycle."}
    end
  end

  # Dispatches the `:env_var_scan_fn` test seam; defaults to
  # `default_env_var_scan/1` (the real shelled scan).
  defp run_env_var_scan(cwd, opts) do
    scan_fn = Keyword.get(opts, :env_var_scan_fn, &default_env_var_scan/1)
    scan_fn.(cwd)
  end

  # Shells `env-var-sample-scan.sh <cwd>` (the extracted scan shared with
  # the retired interactive SubagentStop hook). exit 0 → clean; exit 1 with
  # output → violations (one undocumented VAR name per line, folded into a
  # trimmed string); anything else (missing script, unexpected exit code)
  # is an infra fault — raise (fail-closed), never treat as clean.
  defp default_env_var_scan(cwd) do
    unless File.exists?(@env_var_scan_lib) do
      raise "OrchestrationLoop: env-var-sample-scan.sh not found at #{@env_var_scan_lib}"
    end

    case System.cmd("bash", [@env_var_scan_lib, cwd], stderr_to_stdout: true) do
      {_out, 0} ->
        {:clean}

      {out, 1} ->
        {:violations, String.trim(out)}

      {out, code} ->
        raise "OrchestrationLoop: env-var-sample-scan.sh exited #{code} (expected 0 or 1): #{out}"
    end
  end

  # Creates THIS cycle's log via the sole writer (codegen-log) and returns
  # its resolved path (printed on stdout). Binds by RUN IDENTITY, not slug:
  # `stamp` (this run's own already-minted cycle_id-prefix, or nil for
  # callers with no stamp of their own — e.g. many unit tests) is passed
  # through as --stamp so a retry of the same slug mints its own log instead
  # of silently adopting a predecessor's. init IS idempotent at the
  # exact-path level: re-init naming the SAME slug+stamp (a path that
  # already exists) prints that log's path and exits 0 without creating a
  # second log — safe to call unconditionally at cycle start. A non-zero
  # exit is fatal — a cycle with no log of its own would otherwise silently
  # append its roles' sections into whatever unrelated log happens to be
  # newest on disk.
  @spec default_log_init(String.t(), String.t(), String.t() | nil) :: String.t()
  defp default_log_init(slug, cwd, stamp) do
    unless File.exists?(@codegen_log_bin) do
      raise "OrchestrationLoop: codegen-log not found at #{@codegen_log_bin}"
    end

    args =
      case stamp do
        nil -> ["init", "--slug", slug]
        s -> ["init", "--slug", slug, "--stamp", s]
      end

    {output, exit_code} =
      System.cmd(@codegen_log_bin, args,
        stderr_to_stdout: true,
        env: [{"CODEGEN_DIR", @codegen_dir}, {"CODEGEN_LOG_PATH", nil}],
        cd: cwd
      )

    if exit_code != 0 do
      raise "OrchestrationLoop: codegen-log init --slug #{slug} failed (#{exit_code}): #{output}"
    end

    String.trim(output)
  end

  # Env-list fragment pinning a role's codegen-log writes to THIS cycle's
  # log — CODEGEN_LOG_PATH is codegen-log's highest-precedence resolver, so
  # a role whose own --slug is empty (or whose invocation forgot --slug
  # entirely) still lands in the right file. Empty when no log was
  # initialized (nil slug at cycle start — many unit tests pass none).
  @spec log_path_env() :: [{String.t(), String.t()}]
  defp log_path_env do
    case Process.get(@log_path_key) do
      nil -> []
      path -> [{"CODEGEN_LOG_PATH", path}]
    end
  end

  # CODEGEN_WAIVED_GUARDS: set only for a developer role invocation, to the
  # csv of `waives:` declared by the in-flight codegen/pitches/building/<slug>.md.
  # A guard is relaxed only where a promoted pitch declared that relaxation —
  # scoped to one pitch, one role, one invocation. Absent for every other
  # role (reviewer, curator, committer never write budgets and never see it).
  @spec waived_guards_env(String.t() | nil) :: [{String.t(), String.t()}]
  defp waived_guards_env(role) when is_binary(role) do
    if String.starts_with?(role, "developer") do
      case read_building_waives() do
        "" -> []
        csv -> [{"CODEGEN_WAIVED_GUARDS", csv}]
      end
    else
      []
    end
  end

  defp waived_guards_env(_role), do: []

  # read_building_waives — csv of hook ids from the single in-flight
  # codegen/pitches/building/<slug>.md's `waives:` frontmatter list. Returns
  # "" (never a masked default) on any of: zero or 2+ files in building/, no
  # frontmatter block, no `waives:` line, or an unparseable value — the
  # fail-safe answer is "grant nothing", which waived_guards_env/1 above
  # turns into "omit the env var entirely" (guard enforces).
  @spec read_building_waives() :: String.t()
  defp read_building_waives do
    building_dir = Path.join(@codegen_dir, "codegen/pitches/building")

    case File.ls(building_dir) do
      {:ok, entries} ->
        case Enum.filter(entries, &String.ends_with?(&1, ".md")) do
          [only] -> parse_waives_frontmatter(Path.join(building_dir, only))
          _ -> ""
        end

      {:error, _reason} ->
        ""
    end
  end

  @spec parse_waives_frontmatter(String.t()) :: String.t()
  defp parse_waives_frontmatter(pitch_path) do
    case File.read(pitch_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> extract_waives_line()
        |> case do
          nil -> ""
          line -> normalize_waives_line(line)
        end

      {:error, _reason} ->
        ""
    end
  end

  # extract_waives_line — walks the leading `---`/`---` frontmatter block
  # ONLY (never the pitch body prose, which may mention "waives:" in
  # narrative text) and returns the first line starting with "waives:".
  @spec extract_waives_line([String.t()]) :: String.t() | nil
  defp extract_waives_line(["---" | rest]) do
    Enum.reduce_while(rest, nil, fn
      "---", _acc -> {:halt, nil}
      "waives:" <> _ = line, _acc -> {:halt, line}
      _line, acc -> {:cont, acc}
    end)
  end

  defp extract_waives_line(_lines), do: nil

  @spec normalize_waives_line(String.t()) :: String.t()
  defp normalize_waives_line(line) do
    line
    |> String.replace_prefix("waives:", "")
    |> String.replace(["[", "]"], "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(",")
  end

  # Orientation-doc filter shared by the diff-scope computation below —
  # mirrors the doc grammar in context-factcheck-scan.sh / context-factcheck-guard.sh.
  @orientation_doc_re ~r{^(CLAUDE\.md|AGENTS\.md|PROJECT_CONTEXT\.md|codegen/PROJECT_CONTEXT\.md|context/[^/]+\.md)$}

  # Computes the orientation docs the CURRENT CYCLE changed: uncommitted diff
  # against HEAD (the cycle's own edits are still unstaged/uncommitted at
  # factcheck time — the committer runs after this step) unioned with new
  # untracked orientation docs, filtered to the known orientation-doc grammar.
  # Non-git `cwd` (mocked unit tests, no `.git`) is the ONLY expected non-repo
  # case → empty list (fail-open to {:clean} above — nothing to diff against).
  # Any other git failure (corrupt repo, permissions) is unexpected → raise.
  @spec changed_orientation_docs(String.t()) :: [String.t()]
  defp changed_orientation_docs(cwd) do
    case System.cmd("git", ["rev-parse", "--git-dir"], cd: cwd, stderr_to_stdout: true) do
      {_out, 0} ->
        {diff_out, 0} =
          System.cmd("git", ["diff", "--name-only", "HEAD"], cd: cwd, stderr_to_stdout: false)

        {untracked_out, 0} =
          System.cmd("git", ["ls-files", "--others", "--exclude-standard"],
            cd: cwd,
            stderr_to_stdout: false
          )

        (String.split(diff_out, "\n", trim: true) ++ String.split(untracked_out, "\n", trim: true))
        |> Enum.uniq()
        |> Enum.filter(&Regex.match?(@orientation_doc_re, &1))

      {out, code} ->
        # Expected non-zero cases: "not a git repository" (real repo check
        # failed normally) and code 2 with empty output (cwd does not exist
        # at all — System.cmd's `cd:` cannot chdir there; seen in mocked unit
        # tests using placeholder cwds like "/tmp/irrelevant"). Anything else
        # is an unexpected infra fault — fail loud rather than silently
        # returning [] (which would mask a real problem as "nothing changed").
        cond do
          String.contains?(out, "not a git repository") ->
            []

          code == 2 and out == "" and not File.dir?(cwd) ->
            []

          true ->
            raise "OrchestrationLoop: git rev-parse --git-dir failed unexpectedly in #{cwd}: #{out}"
        end
    end
  end

  # Verdict recognition is UNANIMITY-based, not position-based.
  #
  # The old rule demanded exactly one marker-bearing line AND that it be the
  # final nonblank line. A 180-session sample of real `reviewer-*` outputs
  # says that rule rejects 39% of them, and the single biggest shape (24%,
  # 44/180) is a perfectly well-formed verdict line followed by the
  # reviewer's own action list / findings / closing paragraph — i.e. the
  # verdict was stated, unambiguously, and thrown away over placement.
  # Backtick wrapping (5), a duplicated-but-agreeing marker (1) and
  # `**…** — trailing clause` (1) were thrown away the same way.
  #
  # So: collect EVERY marker-bearing LINE in the body, wherever it sits,
  # classify each with the same anchored `classify_verdict_line/1` the
  # terminality rule already used, and honour the result only when they all
  # agree. That keeps the property the terminality rule was actually bought
  # for — a body carrying a rejection AND an approval is ambiguous and must
  # fail closed (`:unknown`), never resolve to the one that happens to sit
  # last — while dropping the placement demand the model does not reliably
  # obey. A marker-bearing line that is not itself a verdict line classifies
  # `:unknown` and poisons the set the same way a conflict does, rather than
  # being silently skipped in favour of a neighbouring good one.
  #
  # Scanning LINES through the anchored matcher, rather than scanning the raw
  # text for a bare `REVIEW_VERDICT: <WORD>` substring, is what keeps this
  # from fabricating approvals: hedged prose ("I would emit REVIEW_VERDICT:
  # APPROVED if the gate were green") leaves a remainder the anchor rejects,
  # so a body — or a transcript turn — that only ever *discusses* a verdict
  # resolves `:unknown` and re-invokes, exactly as before.
  #
  # Zero conflicts and zero non-enum verdict words occurred in the 180-session
  # sample, so this recovers the discardable placement failures and changes no
  # verdict that already parsed.

  defp parse_review_verdict(%{"value" => value}) when is_binary(value) do
    parse_verdict_text(value)
  end

  defp parse_review_verdict(_), do: :unknown

  # Severity is a loop-side interpretation of an already-valid verdict, not
  # a new wire token. A reviewer can mark every finding `Non-blocking:`; that
  # explicitly permits the build to continue while retaining the findings for
  # post-review curation. Any unprefixed finding remains blocking.
  @spec classify_verdict_severity(map()) ::
          :approved | :approved_with_findings | :changes_requested | :unknown
  defp classify_verdict_severity(review_result) do
    case parse_review_verdict(review_result) do
      :changes_requested ->
        if all_findings_non_blocking?(review_result["value"]) do
          :approved_with_findings
        else
          :changes_requested
        end

      verdict ->
        verdict
    end
  end

  defp all_findings_non_blocking?(value) when is_binary(value) do
    findings =
      value
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.contains?(&1, "REVIEW_VERDICT:"))
      |> Enum.reject(&String.contains?(&1, "REVIEW_COVERAGE:"))

    findings != [] and
      Enum.all?(findings, &(String.trim_leading(&1) |> String.starts_with?("Non-blocking:")))
  end

  defp all_findings_non_blocking?(_), do: false

  defp parse_verdict_text(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "REVIEW_VERDICT:"))
    |> Enum.map(&classify_verdict_line/1)
    |> Enum.uniq()
    |> case do
      [verdict] when verdict != :unknown -> verdict
      _ -> :unknown
    end
  end

  defp parse_verdict_text(_), do: :unknown

  # Normalise presentation, then match the sentinel exactly.
  #
  # Reviewers reliably emit the verdict but decorate it as markdown — it reads
  # as a machine token, so models render it as one (`**bold**`, `` `code` ``,
  # or both). The previous allowlist of accepted byte forms grew one incident
  # at a time and cost a completed, gate-clear, reviewer-APPROVED build because
  # the sentinel arrived in backticks. Formatting cannot be made deterministic
  # by asking, so tolerate it here instead of enumerating wrappers.
  #
  # Anchoring is what keeps this safe. `strip_verdict_decoration/1` only peels
  # *symmetric* pairs from the outside; it never searches inside the line, and
  # the regex then requires the whole remainder to be the sentinel plus one
  # known token. So prose that merely mentions the sentinel ("I would have said
  # REVIEW_VERDICT: APPROVED, but the gate is red"), a trailing suffix, and an
  # unrecognised token all leave a remainder that fails the anchored match and
  # stay `:unknown`. This widens what counts as *parseable*, never what counts
  # as *approved* — the fail-closed refusal in `handle_review/7` is unchanged.
  @verdict_decoration ["`", "*", "_"]
  @verdict_line ~r/^REVIEW_VERDICT:[ \t]*(?<token>[A-Z_]+)$/

  defp classify_verdict_line(line) when is_binary(line) do
    case Regex.named_captures(@verdict_line, strip_verdict_decoration(line)) do
      %{"token" => "APPROVED"} -> :approved
      %{"token" => "CHANGES_REQUESTED"} -> :changes_requested
      _ -> :unknown
    end
  end

  defp classify_verdict_line(_), do: :unknown

  # Cheap failure path. The remaining 11% of the sample returns a value with
  # no verdict in it at all — and 9 of those 20 are the SAME defect wearing a
  # different hat: the reviewer stated its verdict, then called
  # `codegen-log section`, and its post-tool-call closing line ("Logged.",
  # "Recorded.") became the returned value. The verdict is sitting in an
  # earlier assistant turn of a transcript this loop wrote itself.
  #
  # Reading that file costs a stat and a scan; the alternative (what used to
  # happen) is a whole second reviewer invocation that re-reads the diff to
  # re-derive a verdict already on disk. Only ASSISTANT text is scanned —
  # the user turn holds the prompt, which names BOTH enum members and would
  # self-conflict. Unanimity still applies, so a genuinely ambiguous
  # transcript falls through to the re-invocation rather than guessing.
  #
  # When recovery lands, the recovered message REPLACES `"value"`: the
  # `:changes_requested` arm feeds that string to the developer as rework
  # feedback, and "Logged." is not feedback.
  @spec resolve_review(map()) :: {:approved | :changes_requested | :unknown, map()}
  defp resolve_review(review_result) do
    case parse_review_verdict(review_result) do
      :unknown -> recover_review_from_transcript(review_result)
      verdict -> {verdict, review_result}
    end
  end

  defp recover_review_from_transcript(%{"transcript" => path} = review_result)
       when is_binary(path) do
    texts = transcript_assistant_texts(path)

    case parse_verdict_text(Enum.join(texts, "\n")) do
      :unknown ->
        {:unknown, review_result}

      verdict ->
        recovered =
          texts
          |> Enum.filter(&String.contains?(&1, "REVIEW_VERDICT:"))
          |> List.last()

        {verdict, Map.put(review_result, "value", recovered)}
    end
  end

  defp recover_review_from_transcript(review_result), do: {:unknown, review_result}

  # Best-effort stream-json reader: an absent/unreadable/garbage transcript
  # yields [] and the caller falls back to the re-invocation it would have
  # done anyway. Never raises — a recovery attempt must not be able to fail
  # a cycle that was already going to retry.
  defp transcript_assistant_texts(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"type" => "assistant", "message" => %{"content" => content}}}
            when is_list(content) ->
              for %{"type" => "text", "text" => t} <- content, is_binary(t), t != "", do: t

            _ ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # Peels matched outer decoration pairs (and surrounding whitespace) one layer
  # at a time, so nested/mixed wrappers like ``**`…`**`` reduce to the bare
  # line. An unmatched delimiter is left in place — it will fail the anchored
  # match, which is the intended `:unknown`.
  defp strip_verdict_decoration(line) do
    trimmed = String.trim(line)
    first = String.first(trimmed)

    if String.length(trimmed) > 2 and first in @verdict_decoration and
         String.last(trimmed) == first do
      trimmed
      |> String.slice(1..-2//1)
      |> strip_verdict_decoration()
    else
      trimmed
    end
  end

  defp dev_role_from_ctx(ctx) do
    (ctx[:artifacts] || %{})
    |> Map.keys()
    |> Enum.find(fn k -> is_binary(k) and String.starts_with?(k, "developer-") end)
  end

  # An APPROVED verdict asserts nothing about a known surface unless it is
  # paired with a statement of what was read. Before the terminal
  # `REVIEW_VERDICT:` line, the reviewer must emit one `REVIEW_COVERAGE:`
  # line per path in the loop-derived `## Files Modified` set (see pitch
  # "review verdicts name the surface they read") — `<path> read` or
  # `<path> skipped: <reason>`. This checks TOTALITY against the set the
  # loop itself computed, never truth: a reviewer may still legitimately
  # skip a file (a `skipped:` line is a valid, non-blocking answer), but it
  # may not leave the surface unstated. Two independent reviewer passes
  # over the same unchanged tree produced disjoint tool-call sets with no
  # detectable difference in verdict shape — this makes the difference
  # visible and refusable.
  #
  # `expected_files` is the SAME newline-joined value already rendered
  # under `## Files Modified` (`ctx.artifacts.review_file_set`) — no second
  # file walk, no new git call. An empty/blank `expected_files` (nothing
  # changed, or a non-git cwd in mocked tests) is a no-op: `{:ok, %{read:
  # [], skipped: []}}` with no coverage lines required. A real git tree
  # with nothing changed already fails loud one layer up in
  # `invoke_reviewer/4`'s empty-set refusal, so this vacuous branch is
  # unreachable in production — it exists only for the mocked non-git test
  # cwds that make up the bulk of this module's test suite.
  #
  # `{:incomplete, reason}` on: zero coverage lines found while files were
  # expected; a marker-bearing line that fails the anchored per-line match
  # (malformed path, malformed state, or a `skipped:` with an empty
  # reason); a MISSING path (in `expected_files`, absent from the parsed
  # set); or an INVENTED path (present in the parsed set, absent from
  # `expected_files`). The reason names every gap so the re-invocation
  # prompt can quote it verbatim rather than making the reviewer re-derive
  # what was wrong.
  @coverage_line ~r/^REVIEW_COVERAGE:[ \t]*(?<path>\S+)[ \t]+(?<state>read|skipped:.*)$/

  @spec parse_review_coverage(map(), String.t()) ::
          {:ok, %{read: [String.t()], skipped: [{String.t(), String.t()}]}}
          | {:incomplete, String.t()}
  def parse_review_coverage(%{"value" => value} = review_result, expected_files)
      when is_binary(value) and is_binary(expected_files) do
    case parse_review_coverage_text(value, expected_files) do
      {:ok, coverage} ->
        {:ok, coverage}

      {:incomplete, reason} ->
        recover_review_coverage_from_transcript(review_result, expected_files, reason)
    end
  end

  def parse_review_coverage(_, _), do: {:incomplete, "reviewer output was not a text value"}

  defp parse_review_coverage_text(value, expected_files) do
    expected =
      expected_files
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    if MapSet.size(expected) == 0 do
      {:ok, %{read: [], skipped: []}}
    else
      lines = String.split(value, "\n", trim: true)
      coverage_lines = Enum.filter(lines, &String.contains?(&1, "REVIEW_COVERAGE:"))

      if coverage_lines == [] do
        {:incomplete,
         "no REVIEW_COVERAGE: lines found, but ## Files Modified named " <>
           "#{MapSet.size(expected)} path(s): #{Enum.join(Enum.sort(expected), ", ")}"}
      else
        classify_coverage_lines(coverage_lines, expected)
      end
    end
  end

  defp recover_review_coverage_from_transcript(
         %{"transcript" => path},
         expected_files,
         original_reason
       )
       when is_binary(path) do
    path
    |> transcript_assistant_texts()
    |> Enum.filter(&String.contains?(&1, "REVIEW_COVERAGE:"))
    |> Enum.reverse()
    |> Enum.reduce_while({:incomplete, original_reason}, fn text, fallback ->
      case parse_review_coverage_text(text, expected_files) do
        {:ok, _coverage} = ok -> {:halt, ok}
        {:incomplete, _reason} -> {:cont, fallback}
      end
    end)
  end

  defp recover_review_coverage_from_transcript(_review_result, _expected_files, original_reason) do
    {:incomplete, original_reason}
  end

  defp classify_coverage_lines(coverage_lines, expected) do
    {parsed, malformed} =
      Enum.reduce(coverage_lines, {[], []}, fn line, {parsed_acc, malformed_acc} ->
        case classify_coverage_line(line) do
          {:ok, entry} -> {[entry | parsed_acc], malformed_acc}
          :malformed -> {parsed_acc, [line | malformed_acc]}
        end
      end)

    parsed = Enum.reverse(parsed)
    malformed = Enum.reverse(malformed)

    if malformed != [] do
      {:incomplete, "malformed REVIEW_COVERAGE line(s): #{Enum.join(malformed, " | ")}"}
    else
      parsed_paths = parsed |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      missing = MapSet.difference(expected, parsed_paths)
      invented = MapSet.difference(parsed_paths, expected)

      cond do
        MapSet.size(missing) > 0 ->
          {:incomplete,
           "REVIEW_COVERAGE missing #{MapSet.size(missing)} path(s) from ## Files Modified: " <>
             Enum.join(Enum.sort(missing), ", ")}

        MapSet.size(invented) > 0 ->
          {:incomplete,
           "REVIEW_COVERAGE named #{MapSet.size(invented)} path(s) not in ## Files Modified: " <>
             Enum.join(Enum.sort(invented), ", ")}

        true ->
          read = for {path, :read} <- parsed, do: path
          skipped = for {path, {:skipped, reason}} <- parsed, do: {path, reason}
          {:ok, %{read: read, skipped: skipped}}
      end
    end
  end

  defp classify_coverage_line(line) do
    case Regex.named_captures(@coverage_line, strip_verdict_decoration(line)) do
      %{"path" => path, "state" => "read"} ->
        {:ok, {path, :read}}

      %{"path" => path, "state" => "skipped:" <> reason} ->
        reason = String.trim(reason)
        if reason == "", do: :malformed, else: {:ok, {path, {:skipped, reason}}}

      _ ->
        :malformed
    end
  end

  # Runs the gate once (developer already ran) and returns the verdict atom.
  #
  # THE REVIEW-REWORK RE-GATE. Sole caller: `handle_review/7`'s
  # `:changes_requested` arm, after the developer has reworked and
  # `run_format_step/2` has run. That rework can be a no-op — the developer
  # can come back blocked, or answer the review in prose — and then this
  # re-gate pays 100-160s to re-derive a verdict already on disk for the
  # byte-identical tree. Real occurrence: cycle log
  # `20260806_055519_adhoc_cycle.jsonl`, gate #2 at 06:03:32, 100s, tree
  # a8da05e8 — the same tree gate #1 graded clear 92 seconds earlier.
  #
  # So: consult `cached_clear_gate/2` FIRST and return `:clear` without
  # entering `LoopGate.run_gate/2` at all. Skipping at the CALL SITE (not
  # inside `run_gate/2`) is load-bearing — `run_gate/2`'s very first
  # statement unlinks `gate-result.json`, and that unlink must keep firing
  # for every run that really happens. Never reaching it is what leaves the
  # existing artifact intact for the reviewer, `codegen-commit`'s
  # `.verdict == clear` check, and `assert_commit_matches_gate!/1`.
  #
  # Only THIS site is guarded. The other five `run_gate/2` call sites are
  # left alone on purpose, and the exclusion is structural rather than a
  # consequence of the guard's own conditions:
  #
  #   * `do_gate_loop_flake_check/10` and
  #     `do_gate_loop_stale_build_flake_check/10` exist precisely to re-run
  #     an unchanged tree and see whether a red reproduces.
  #   * `do_gate_loop_stale_build_heal/10` re-gates after `rm -rf _build`.
  #     `_build/` is gitignored, so `graded_tree_sha` is byte-identical
  #     across the heal — a tree-sha skip there is a permanent no-op.
  #   * `rework_final_gate/5` is only reached on a known tree MISMATCH.
  #   * `do_gate_loop/9`'s entry gate is skippable in principle (a developer
  #     turn that changed nothing) but is the cycle's FIRST gate, where the
  #     only thing on disk is a previous build's record; that needs a
  #     cross-build policy this change does not make.
  defp run_gate_once(ctx, opts) do
    gate_opts = gate_opts(opts, ctx)

    case cached_clear_gate(ctx.cwd, gate_opts) do
      {:cached, facts, gate, mode} ->
        note_cached_gate(gate_opts, facts, gate, mode)
        :clear

      :miss ->
        gate_fn = Keyword.get(opts, :gate_fn, &LoopGate.run_gate/2)
        {verdict, _cmd} = gate_fn.(ctx.cwd, gate_opts)
        verdict
    end
  end

  # "Is the work in front of us PROVABLY already graded clear?" — the
  # cached-gate predicate. `{:cached, facts, gate, mode}` only when every
  # conjunct below holds; `:miss` otherwise, and `:miss` on ANY doubt.
  #
  # Read this as the mirror image of `default_gate_tree_match?/1` (:1074),
  # and do NOT be tempted to reuse that function here. It answers "must I
  # FORCE a re-gate?", so its `graded == "" or current == ""` treats an
  # unknown signature as "no evidence of drift" → true. That fail-OPEN is
  # correct there and catastrophic here: an empty sentinel is exactly what a
  # non-git cwd, an unborn HEAD, or a legacy gate-result.json produces, and
  # reusing it would skip the gate in every one of those cases. Every
  # sentinel below therefore fails CLOSED.
  #
  #   1. `verdict == "clear"`. Never skip a red. A failure must stay
  #      re-provable or one flake becomes a permanent verdict. Read as the
  #      literal field rather than through `LoopGate.read_verdict/1` so
  #      "inconclusive", a malformed record and an absent file all land on
  #      the same `:miss` instead of raising.
  #   2. `cycle_id` non-empty on BOTH sides and equal. Nothing clears
  #      `gate-result.json` at cycle start (`run/1` unlinks only
  #      `terminal-state.json`; `codegen-build`'s eager `rm -f` was removed
  #      deliberately — context/fail-closed-posture.md:27), so a fresh build
  #      routinely starts with the PREVIOUS build's `clear` record sitting on
  #      disk. Tree-sha equality alone would read that as a pass. The
  #      non-empty half is not decoration: `""` is what every pre-`cycle_id`
  #      record, and every gate run outside a loop, carries — and `""` is
  #      also what `gate_opts/2` supplies when no cycle id was set, so
  #      `"" == ""` would wave through precisely the stale cross-build record
  #      this conjunct exists to catch.
  #   3. `graded_tree_sha` non-empty on both sides and equal. The
  #      signature covers HEAD's tree plus tracked modifications, deletions
  #      and untracked non-ignored files (`git ls-files -m -d -o
  #      --exclude-standard`), which is the whole surface a developer's
  #      rework turn can touch and have the gate read. It does NOT cover
  #      gitignored state — `_build/`, `deps/`, `node_modules/`, `codegen/`
  #      — nor the toolchain. Conjunct 2 is what bounds that gap: cache hits
  #      can only occur within one build, minutes apart, and a dependency
  #      change large enough to flip a verdict moves `mix.lock`, which IS in
  #      the signature.
  #   4. `gate` non-empty on both sides and equal. A mid-cycle edit to
  #      `.claude/gate-config.sh` changes what "graded" means; the stamped
  #      command is the only record of what was actually run.
  #
  # Ordered cheapest-first and short-circuiting: one `File.read` before any
  # git work, and `LoopGate.decide_gate/1`'s bash spawn last of all. That
  # ordering also keeps `decide_gate/1` — which RAISES on an unresolvable
  # gate — off the path for every cwd that was never going to hit, which is
  # every mocked unit test. Should it raise anyway, the rescue turns it into
  # `:miss` and the real `run_gate/2` re-raises it a moment later, after its
  # own unlink has fired. The guard may cost a cycle time; it may never cost
  # it correctness.
  @spec cached_clear_gate(String.t(), run_opts()) ::
          {:cached, map(), String.t(), String.t()} | :miss
  defp cached_clear_gate(cwd, gate_opts) do
    cycle_id = gate_result_string(Keyword.get(gate_opts, :cycle_id))

    with {:ok, facts} <- gate_result_facts(cwd),
         true <- facts.verdict == "clear",
         true <- cycle_id != "" and facts.cycle_id == cycle_id,
         true <- facts.graded_tree_sha != "",
         true <- facts.graded_tree_sha == LoopGate.graded_tree_sha_now(cwd),
         true <- facts.gate != "",
         {gate, mode, _timeout} <- LoopGate.decide_gate(cwd),
         true <- facts.gate == gate do
      {:cached, facts, gate, mode}
    else
      _ -> :miss
    end
  rescue
    _ -> :miss
  end

  # The six `gate-result.json` fields the cached-gate predicate and its
  # cycle-log event need, in ONE read. Decoded here rather than through
  # `gate-result.sh`'s per-field bash readers: six `bash -c` + `jq` spawns
  # to decide whether to skip would be a real fraction of the skip's own
  # value, and every field is a plain string. `:error` (never a partial
  # map) on anything unreadable.
  @spec gate_result_facts(String.t()) :: {:ok, map()} | :error
  defp gate_result_facts(cwd) do
    path = Path.join(cwd, "codegen/gate-pending/gate-result.json")

    with {:ok, contents} <- File.read(path),
         {:ok, %{} = json} <- Jason.decode(contents) do
      {:ok,
       %{
         verdict: gate_result_string(json["verdict"]),
         verdict_marker: gate_result_string(json["verdict_marker"]),
         graded_tree_sha: gate_result_string(json["graded_tree_sha"]),
         cycle_id: gate_result_string(json["cycle_id"]),
         gate: gate_result_string(json["gate"]),
         started: gate_result_string(json["started"])
       }}
    else
      _ -> :error
    end
  end

  # Absent/null/non-string JSON field → "", the sentinel every conjunct in
  # `cached_clear_gate/2` rejects.
  defp gate_result_string(value) when is_binary(value), do: value
  defp gate_result_string(_value), do: ""

  # Make the skip visible in both places a gate run is normally visible:
  # operator stderr, and the cycle log's `{"ev":"gate"}` stream. Routed
  # through the SAME `:log_verdict_fn` seam and the same 5-arity shape
  # `LoopGate.run_gate/2` uses for a real verdict, so anything already
  # watching gate events sees this one too — distinguished by a `cached:`
  # detail naming the tree and the timestamp of the run being reused, since
  # after a skip the stamped `started`/`ended`/`duration_s`/`session_id` all
  # describe that earlier run and not this step.
  #
  # An empty `verdict_marker` (a hand-written or legacy record) makes
  # `default_log_verdict/5` no-op rather than write a bogus event; the
  # stderr note still fires, so the skip is never completely silent.
  @spec note_cached_gate(run_opts(), map(), String.t(), String.t()) :: :ok
  defp note_cached_gate(gate_opts, facts, gate, mode) do
    short_sha = String.slice(facts.graded_tree_sha, 0, 12)

    operator_note(
      "codegen.loop: re-work re-gate SKIPPED — tree #{short_sha} was already graded " <>
        "clear by `#{gate}` in this cycle at #{facts.started}; reusing that verdict"
    )

    detail =
      "cached: tree #{short_sha} already graded clear in this cycle at #{facts.started} " <>
        "— gate not re-run"

    log_verdict_fn = Keyword.get(gate_opts, :log_verdict_fn, &LoopGate.log_cached_verdict/5)
    log_verdict_fn.(Keyword.get(gate_opts, :cycle_log), gate, mode, facts.verdict_marker, detail)

    :ok
  end

  # After a developer role completes, run the gate. Clear → continue to the
  # reviewer/curator/committer tail. Non-clear → re-invoke the SAME
  # developer role (once, up to :max_gate_retries) with the gate's reason
  # folded into context; if still non-clear, {:error, reason}.
  defp run_gate_then_continue(dev_role, rest, harness, ctx, opts) do
    gate_fn = Keyword.get(opts, :gate_fn, &LoopGate.run_gate/2)
    max_retries = Keyword.get(opts, :max_gate_retries, 1)

    do_gate_loop(dev_role, rest, harness, ctx, opts, gate_fn, max_retries, 0, nil)
  end

  # Adds :cycle_log (THIS cycle's log path, from Process.get(@log_path_key))
  # to opts before it reaches LoopGate.run_gate/2 — the gate itself has no
  # way to resolve the log path; the loop is the sole holder of it (set by
  # default_log_init/3 at cycle start, or nil when no log was initialized,
  # e.g. most unit tests). Adds a key only; never overwrites a :cycle_log a
  # test already supplied in opts.
  #
  # Also adds :session_id — the acting developer role for THIS gate run, so
  # `gate-verdicts.jsonl` records an attributable actor instead of the
  # anonymous "" LoopGate.run_gate/2 defaults to (pitch
  # "build-cycle-accounts-for-its-own-time" Move 5). `actor` (when given) is
  # the caller's own already-known dev_role (do_gate_loop/9,
  # rework_final_gate/5); nil callers (run_gate_once/2, which has no
  # dev_role parameter) fall back to dev_role_from_ctx/1. Never overwrites a
  # :session_id a test already supplied in opts.
  @spec gate_opts(run_opts()) :: run_opts()
  defp gate_opts(opts), do: gate_opts(opts, nil)

  @spec gate_opts(run_opts(), map() | String.t() | nil) :: run_opts()
  defp gate_opts(opts, dev_role) when is_binary(dev_role) do
    opts
    |> Keyword.put_new(:cycle_log, Process.get(@log_path_key))
    |> Keyword.put_new(:session_id, dev_role)
    |> Keyword.put_new(:cycle_id, Process.get(@cycle_id_key) || "")
  end

  defp gate_opts(opts, ctx) when is_map(ctx) or is_nil(ctx) do
    opts
    |> Keyword.put_new(:cycle_log, Process.get(@log_path_key))
    |> Keyword.put_new(:session_id, gate_actor(ctx))
    |> Keyword.put_new(:cycle_id, Process.get(@cycle_id_key) || "")
  end

  defp gate_actor(nil), do: ""
  defp gate_actor(ctx), do: dev_role_from_ctx(ctx) || ""

  # Hard ceiling backstop: even with continuous progress, a run/1 cycle never
  # re-invokes the developer for gate failures more than this many times.
  @gate_progress_ceiling 15

  # Hard ceiling backstop for the curator-doc and env-var repair loops (see
  # `repair_allowed?/4`). Deliberately the SAME value as
  # `@gate_progress_ceiling` — one number to reason about across every
  # progress-bounded loop in this module — but a SEPARATE attribute because
  # it bounds a distinct loop (repair-turn budget, not gate re-run budget);
  # tuning one must never silently move the other.
  @repair_progress_ceiling 15

  # Splits a scan's violation text into a set of trimmed, non-blank lines.
  # Both curator-doc scans (`context-index-parity-scan.sh`,
  # `context-factcheck-scan.sh`) and the env-var scan
  # (`env-var-sample-scan.sh`) emit one violation per line, and
  # `combine_curator_doc_results/2` joins multi-leg violations with "\n" —
  # so line-splitting needs no scan-side change. Used only to compare
  # "what did the prior scan complain about" against "what does the current
  # scan complain about" — never displayed, never re-parsed for structure.
  @spec violation_set(String.t()) :: MapSet.t(String.t())
  defp violation_set(violations) do
    violations
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> MapSet.new()
  end

  # Floor-guaranteed, then progress-bounded, then hard-ceiling-capped repair
  # loop gate shared by `run_curator_doc_check_rework/9` and
  # `run_env_var_step_rework/9`. `cycle < max_cycles` is kept as the FIRST
  # disjunct so `:max_curator_doc_cycles`/`:max_env_var_cycles` become a
  # GUARANTEED FLOOR rather than a ceiling: every existing caller's exact
  # count-based behavior at/under the floor is preserved byte-for-byte
  # (default 1 → the first rework is always granted; 0 → never rework).
  # Beyond the floor, a rework is granted ONLY when the repairing role
  # provably resolved at least one violation from the immediately prior
  # scan (`prior_set` is not a subset of `current_set` — i.e. at least one
  # prior violation is gone). `prior_set` is `nil` on the very first call
  # (no prior scan to compare against), which makes `resolved_any?` false
  # and therefore never grants a turn past the floor on cycle 0 — correct,
  # since there is nothing yet to have resolved. A role that thrashes
  # (identical violation set) or introduces a superset (fixes nothing, adds
  # more) is refused at exactly the same turn as before this bound existed;
  # only a converging repair earns turns past the floor, and even then never
  # past `@repair_progress_ceiling`.
  @spec repair_allowed?(non_neg_integer(), non_neg_integer(), String.t() | nil, String.t()) ::
          boolean()
  defp repair_allowed?(cycle, max_cycles, prev_violations, violations) do
    resolved_any? =
      case prev_violations do
        nil ->
          false

        prev ->
          prior_set = violation_set(prev)
          current_set = violation_set(violations)
          not MapSet.subset?(prior_set, current_set)
      end

    cycle < @repair_progress_ceiling and (cycle < max_cycles or resolved_any?)
  end

  # Progress+ceiling bound for developer gate re-runs:
  #
  # - `attempt` counts prior developer re-invocations for this gate loop.
  # - `prev_signature` is the tree content-hash captured at the PRIOR gate
  #   run (nil on the first attempt). When the signature is available
  #   ("" is treated as unavailable -- non-git cwd, e.g. every existing
  #   gate_fn-stub unit test that passes a synthetic "/tmp/irrelevant" cwd),
  #   a re-invocation is allowed only when the tree actually changed since
  #   the last gate run (progress) AND the hard ceiling has not been hit.
  #   When the signature is unavailable, the bound falls back to the legacy
  #   raw :max_gate_retries count (still capped by the hard ceiling) so
  #   existing count-based tests are unaffected.
  defp do_gate_loop(
         dev_role,
         rest,
         harness,
         ctx,
         opts,
         gate_fn,
         max_retries,
         attempt,
         prev_signature
       ) do
    case gate_fn.(ctx.cwd, gate_opts(opts, dev_role)) do
      {:clear, _gate_cmd} ->
        advance_cycle_state_step("GATED", ctx, opts)

        # A developer gate failure is not the NEXT role's "previous attempt"
        # — once the gate goes clear, drop the stale reason so it never
        # leaks into the reviewer (or any later role) prompt as a fault that
        # isn't theirs (pitch "reviewer handoff names the files under
        # review").
        ctx = update_in(ctx, [:artifacts], &Map.delete(&1, :last_failure_reason))
        run_roles(rest, harness, ctx, opts)

      {:failed, gate_cmd} ->
        classify_fn = Keyword.get(opts, :gate_classify_fn, &default_gate_classify_fn/2)

        case classify_fn.(ctx.cwd, dev_role) do
          :infra ->
            reason = gate_failure_reason(ctx.cwd)

            LoopGate.infra_abort!(
              "gate",
              "failed for a reason no developer edit can fix (classified :infra) — " <>
                "#{reason}"
            )

          :stale_build ->
            do_gate_loop_stale_build_flake_check(
              dev_role,
              rest,
              harness,
              ctx,
              opts,
              gate_fn,
              gate_cmd,
              max_retries,
              attempt,
              prev_signature
            )

          {:owner, owner_role} ->
            do_gate_loop_flake_check(
              owner_role,
              rest,
              harness,
              ctx,
              opts,
              gate_fn,
              gate_cmd,
              max_retries,
              attempt,
              prev_signature
            )
        end

      {other, _gate_cmd} ->
        raise "OrchestrationLoop: unexpected gate verdict #{inspect(other)}"
    end
  end

  # One standalone re-run of the SAME gate command, serially, before any
  # rework attempt is consumed — absorbs a LOAD FLAKE (a check green
  # standalone, red only under `make test`'s parallel fan-out). Only ever
  # runs ONCE per gate-failure occurrence (`attempt` is not incremented on
  # this leg, so a repeated flake on the re-run itself is not re-flake-
  # checked — it proceeds to real routing exactly like any other red).
  #
  # Green standalone -> load flake: re-run the FULL gate once more (does
  # NOT consume a rework attempt) and re-enter `do_gate_loop/9` fresh — a
  # second consecutive red at that point is treated as genuinely red, never
  # re-flake-checked again.
  #
  # Red standalone -> real failure -> `do_gate_loop_rework/10` routes to the
  # resolved OWNER (not always the developer).
  defp do_gate_loop_flake_check(
         owner_role,
         rest,
         harness,
         ctx,
         opts,
         gate_fn,
         gate_cmd,
         max_retries,
         attempt,
         prev_signature
       ) do
    flake_check_fn = Keyword.get(opts, :flake_check_fn, gate_fn)

    case flake_check_fn.(ctx.cwd, gate_opts(opts)) do
      {:clear, ^gate_cmd} ->
        operator_note(
          "gate #{inspect(gate_cmd)}: passed standalone — treating as load flake, " <>
            "re-running gate (attempt not consumed)"
        )

        do_gate_loop(
          owner_role,
          rest,
          harness,
          ctx,
          opts,
          gate_fn,
          max_retries,
          attempt,
          prev_signature
        )

      {_verdict, _cmd} ->
        do_gate_loop_rework(
          owner_role,
          rest,
          harness,
          ctx,
          opts,
          gate_fn,
          max_retries,
          attempt,
          prev_signature
        )
    end
  end

  # A :stale_build verdict that PASSES a standalone re-run is a concurrency
  # load flake (mass `UndefinedFunctionError` from racing the running
  # orchestrator's own `_build` access), not a genuinely stale committed
  # build — a genuinely stale build cannot coexist with an orchestrator
  # process that already booted from it. Mirrors
  # `do_gate_loop_flake_check/10`'s shape exactly: green standalone -> no
  # nuke, re-enter `do_gate_loop/9` fresh (attempt not consumed). Red
  # standalone -> proceed to the destructive heal, which is now reserved for
  # a genuinely stale (non-live) build root. See
  # `a-gate-flake-under-concurrency-is-not-a-stale-build` pitch.
  defp do_gate_loop_stale_build_flake_check(
         dev_role,
         rest,
         harness,
         ctx,
         opts,
         gate_fn,
         gate_cmd,
         max_retries,
         attempt,
         prev_signature
       ) do
    flake_check_fn = Keyword.get(opts, :flake_check_fn, gate_fn)

    case flake_check_fn.(ctx.cwd, gate_opts(opts)) do
      {:clear, ^gate_cmd} ->
        operator_note(
          "gate #{inspect(gate_cmd)}: stale-_build verdict passed standalone — " <>
            "treating as load flake, re-running gate (attempt not consumed)"
        )

        do_gate_loop(
          dev_role,
          rest,
          harness,
          ctx,
          opts,
          gate_fn,
          max_retries,
          attempt,
          prev_signature
        )

      {_verdict, _cmd} ->
        do_gate_loop_stale_build_heal(
          dev_role,
          rest,
          harness,
          ctx,
          opts,
          gate_fn,
          gate_cmd,
          max_retries,
          attempt,
          prev_signature
        )
    end
  end

  # Resolves the `:live_build_root_fn` test seam — the build root the
  # RUNNING orchestrator process itself executes from. Defaults to the
  # process's own `_build` under its current working directory (on a
  # codegen self-build, that cwd IS `test_harness/` — see
  # `harnesses/claude/dispatch.sh`'s `LOOP_DIR="$CODEGEN_DIR/test_harness"`
  # + `cd "$1"`). The heal must never `rm_rf` this path.
  @spec default_live_build_root_fn() :: String.t()
  defp default_live_build_root_fn do
    Path.join(Path.expand(File.cwd!()), "_build")
  end

  # Default `:stale_build_heal_fn` — nukes candidate compiled-artifact roots
  # under `cwd` (a downstream app's own `_build`, and its
  # `test_harness/_build` if present), EXCEPT any candidate that resolves to
  # the LIVE orchestrator's own build root (`:live_build_root_fn`) — nuking
  # that out from under the running process guarantees the next gate entry
  # finds a half-recompiled `_build`, re-triggers the same stale signature,
  # and the heal chases its own tail. `File.rm_rf!/1` is a no-op where a
  # root is absent, so skipping the live root and nuking the rest
  # unconditionally is safe and stack-agnostic. Compile-only: no
  # `deps.get` — a stale build is stale artifacts, not missing deps; the
  # gate re-run's own `mix compile` step rebuilds everything it needs.
  @spec default_stale_build_heal_fn(String.t(), (-> String.t())) :: :ok
  defp default_stale_build_heal_fn(cwd, live_root_fn) do
    live_root = live_root_fn.()

    for candidate <- [Path.join(cwd, "_build"), Path.join([cwd, "test_harness", "_build"])] do
      if Path.expand(candidate) == Path.expand(live_root) do
        operator_note(
          "gate: skipping stale-_build heal for #{candidate} — it is the LIVE " <>
            "orchestrator build root; nuking it would corrupt the running process"
        )
      else
        File.rm_rf!(candidate)
      end
    end

    :ok
  end

  # A stale `_build` (compiled artifacts predating current source) makes
  # `mix test` emit mass `** (UndefinedFunctionError) ... module Foo is
  # not available` for every call into an unloaded module — classified
  # `:stale_build` by `default_gate_classify_fn/2`. This is NOT a code
  # defect (no edit can fix it) and NOT an infra fault (a rebuild clears
  # it instantly) — routing it to developer rework wastes a cycle, and
  # routing it to `:infra` would abort the whole queue (InfraAbort exit 3)
  # on a box a `mix compile` would fix in seconds. See
  # `a-stale-_build-must-not-halt-the-queue-as-a-false-infra-fault` pitch.
  #
  # Heals AT MOST ONCE per gate-failure occurrence: nukes `_build`, re-runs
  # the SAME gate command directly (not via the full `do_gate_loop`
  # recursion) WITHOUT consuming a rework attempt. Clear -> proceed via
  # `do_gate_loop/9` fresh (mirrors the flake-check green path). Still
  # `:failed` -> classify once more; ANY verdict (including a repeated
  # `:stale_build`) routes to ordinary rework via `do_gate_loop_flake_check/10`
  # so a rebuild that doesn't help is never re-healed in a loop.
  defp do_gate_loop_stale_build_heal(
         dev_role,
         rest,
         harness,
         ctx,
         opts,
         gate_fn,
         gate_cmd,
         max_retries,
         attempt,
         prev_signature
       ) do
    live_root_fn = Keyword.get(opts, :live_build_root_fn, &default_live_build_root_fn/0)
    heal_fn = Keyword.get(opts, :stale_build_heal_fn, &default_stale_build_heal_fn/2)

    operator_note(
      "gate #{inspect(gate_cmd)}: stale _build detected (module load failures) — " <>
        "rebuilding and re-running (attempt not consumed)"
    )

    heal_fn.(ctx.cwd, live_root_fn)

    case gate_fn.(ctx.cwd, gate_opts(opts, dev_role)) do
      {:clear, _cmd} ->
        operator_note(
          "gate #{inspect(gate_cmd)}: passed after stale-_build rebuild — re-running gate " <>
            "(attempt not consumed)"
        )

        do_gate_loop(
          dev_role,
          rest,
          harness,
          ctx,
          opts,
          gate_fn,
          max_retries,
          attempt,
          prev_signature
        )

      {_verdict, _cmd} ->
        # Rebuild did not clear it (or it re-classifies as :stale_build
        # again) — treat as a genuine failure, route through the normal
        # owner-resolution/flake-check/rework path exactly once, never
        # re-entering the heal leg.
        owner_role = resolve_gate_owner(ctx.cwd, dev_role)

        do_gate_loop_flake_check(
          owner_role,
          rest,
          harness,
          ctx,
          opts,
          gate_fn,
          gate_cmd,
          max_retries,
          attempt,
          prev_signature
        )
    end
  end

  # An owning role's edit CAN plausibly fix this gate failure — run the
  # existing progress+ceiling-bounded rework logic (unchanged from before
  # infra classification was added; see `do_gate_loop/9`'s `:infra` branch
  # above for the sibling that never reaches here). `dev_role` here is the
  # RESOLVED OWNER (developer or context-curator), not necessarily the
  # original cycle's developer — see `default_gate_classify_fn/2`.
  defp do_gate_loop_rework(
         dev_role,
         rest,
         harness,
         ctx,
         opts,
         gate_fn,
         max_retries,
         attempt,
         prev_signature
       ) do
    signature_fn = Keyword.get(opts, :tree_signature_fn, &tree_signature/1)
    signature = signature_fn.(ctx.cwd)

    progressed? = signature != "" and prev_signature != nil and signature != prev_signature
    first_attempt? = prev_signature == nil
    signature_available? = signature != ""

    allow? =
      attempt < @gate_progress_ceiling and
        if signature_available? do
          first_attempt? or progressed?
        else
          attempt < max_retries
        end

    if allow? do
      reason = gate_failure_reason(ctx.cwd)
      brief = capture_rework_brief(ctx.cwd, opts)

      # This attempt is the FINAL one the bound will allow if the NEXT
      # attempt (attempt + 1) would already be refused for a reason that
      # cannot change between now and then (the hard ceiling, or the
      # count-based bound when no tree signature is available). It is NOT
      # final merely because the signature-based `progressed?` bound would
      # refuse it — that depends on whether THIS attempt's own edit changes
      # the tree, which is unknown yet. Escalating only on the
      # ceiling/count-bound exhaustion keeps the ~1.8% give-up-boundary
      # frequency this bet is sized on (see pitch claim ledger #1); treating
      # every signature-bound refusal as "final" would escalate far more
      # often, on cycles that are converging normally rather than stuck.
      final_attempt? =
        attempt + 1 >= @gate_progress_ceiling or
          (not signature_available? and attempt + 1 >= max_retries)

      retry_ctx =
        ctx
        |> put_in([:artifacts, :last_failure_reason], reason)
        |> put_in([:artifacts, :rework_brief], brief)
        |> maybe_escalate_model(dev_role, harness, opts, final_attempt?)
        |> maybe_advise(dev_role, harness, opts, final_attempt?, %{
          stage: "gate_loop_rework",
          attempt: attempt + 1,
          ceiling: @gate_progress_ceiling,
          repro_count: attempt + 1
        })

      with {:ok, result} <- invoke_with_retry(dev_role, harness, retry_ctx, opts) do
        ctx =
          retry_ctx
          |> put_in([:artifacts, dev_role], result)
          |> update_in([:artifacts], &Map.delete(&1, :escalated_model))
          |> update_in([:artifacts], &Map.delete(&1, :advisor_plan))

        run_format_step(ctx.cwd, opts)

        do_gate_loop(
          dev_role,
          rest,
          harness,
          ctx,
          opts,
          gate_fn,
          max_retries,
          attempt + 1,
          signature
        )
      end
    else
      write_terminal_marker(ctx.cwd, "gate verdict=failed", dev_role)
      {:error, "gate verdict=failed after #{attempt + 1} #{dev_role} attempt(s)"}
    end
  end

  # Writes `codegen/gate-pending/terminal-state.json` — a durable, per-cycle
  # marker distinguishing a DETERMINISTIC exhaustion ("this cycle cannot
  # succeed however many times you run it") from a RECOVERABLE transient
  # exit (a process death mid-cycle, resume-worthy). `LoopQueueDrain` reads
  # this marker BEFORE `retry_eligible?/5` and, when present, routes to the
  # existing park+skip+breaker channel instead of blind-retrying at full
  # `codegen-build` price — see the pitch "route an exhausted or
  # deterministic failure to its owner".
  #
  # Blast-radius rule (deliberately, not exit 3 / InfraAbort — but see the
  # write-failure posture below, which IS exit 3): every caller of this
  # function is PITCH-SPECIFIC (this cycle's own gate/doc/env exhaustion) —
  # the NEXT pitch is unaffected on a SUCCESSFUL marker write, so the queue
  # should drain on rather than HALT. Exit 3 / `InfraAbort` stays reserved
  # for genuinely repo-wide faults (see `LoopGate.infra_abort!/2`) — normally
  # untouched by this function, EXCEPT when the marker write itself fails.
  #
  # REQUIRED, not best-effort: `LoopQueueDrain` reads this marker BEFORE
  # `retry_eligible?/5` to distinguish a deterministic exhaustion from a
  # retryable transient. A silently-lost write leaves the accompanying
  # `{:error, ...}` UNMARKED — the queue can then blind-retry a pitch that
  # can never succeed, at full `codegen-build` price, instead of parking it
  # under its named owner. A write failure here is therefore itself an
  # infra fault: raise via `LoopGate.infra_abort!/2` rather than degrading
  # to a stderr note.
  @spec write_terminal_marker(String.t(), String.t(), String.t() | nil) :: :ok
  defp write_terminal_marker(cwd, reason, owner) do
    dir = Path.join([cwd, "codegen", "gate-pending"])
    path = Path.join(dir, "terminal-state.json")

    payload = Jason.encode!(%{terminal: true, reason: reason, owner: owner})

    case File.mkdir_p(dir) do
      :ok ->
        case File.write(path, payload) do
          :ok ->
            :ok

          {:error, write_reason} ->
            LoopGate.infra_abort!(
              "terminal-marker-write",
              "failed to write #{path}: #{inspect(write_reason)} — a deterministic " <>
                "exhaustion (#{reason}) would be left unmarked, risking a blind queue retry."
            )
        end

      {:error, mkdir_reason} ->
        LoopGate.infra_abort!(
          "terminal-marker-write",
          "failed to create #{dir}: #{inspect(mkdir_reason)} — a deterministic " <>
            "exhaustion (#{reason}) would be left unmarked, risking a blind queue retry."
        )
    end
  end

  # Applies a model/effort escalation override into `ctx.artifacts.escalated_model`
  # for the NEXT developer invocation, but only when `final_attempt?` is true
  # (this rework attempt is the last the bound allows before give-up) AND
  # `config.yaml` actually carries an escalation tier for this role/harness
  # (`RoleResolver.resolve_escalation/2` — fail-safe `:none` when absent, per
  # its own contract). Not final, or no escalation configured -> ctx passes
  # through unchanged, i.e. the role runs at its normal tier exactly as
  # before this feature existed.
  @spec maybe_escalate_model(map(), String.t(), harness(), run_opts(), boolean()) :: map()
  defp maybe_escalate_model(ctx, dev_role, harness, opts, final_attempt?)

  defp maybe_escalate_model(ctx, _dev_role, _harness, _opts, false), do: ctx

  defp maybe_escalate_model(ctx, dev_role, build_harness, opts, true) do
    resolve_harness_fn =
      Keyword.get(opts, :resolve_harness_fn, &RoleResolver.resolve_harness/2)

    harness = resolve_harness_fn.(dev_role, build_harness)

    # A role-model-sweep campaign arm holds this role's binding fixed for the
    # whole invocation — escalating on the final gate-retry attempt would
    # silently measure a DIFFERENT (stronger) tier than the one the campaign
    # requested, corrupting the arm's evidence. Suppress: the role stays
    # pinned and, if it never gates green, the arm reports INCONCLUSIVE
    # rather than a quietly-substituted binding.
    if resolve_fixed_binding(dev_role, harness, opts) != :none do
      ctx
    else
      do_maybe_escalate_model(ctx, dev_role, harness, opts)
    end
  end

  defp do_maybe_escalate_model(ctx, dev_role, harness, opts) do
    escalate_fn = Keyword.get(opts, :resolve_escalation_fn, &RoleResolver.resolve_escalation/2)

    case escalate_fn.(dev_role, harness) do
      {model, effort} ->
        operator_note(
          "role #{dev_role}: escalating to #{model}/#{effort} on final gate-retry attempt before give-up"
        )

        put_in(ctx, [:artifacts, :escalated_model], {model, effort})

      :none ->
        ctx
    end
  end

  # Calls the advisor (`codegen-advise`) exactly once, at
  # the SAME give-up boundary `maybe_escalate_model/5` already fires at
  # (`final_attempt?` true), and stashes the returned diagnosis object at
  # `ctx.artifacts.advisor_plan` for `build_prompt/2` to render under
  # `## Advisor`. Composes with escalation: the final attempt can carry BOTH
  # a stronger same-provider model (`:escalated_model`) AND an
  # advisor diagnosis (`:advisor_plan`) — orthogonal artifact
  # keys, both cleared by the caller after the attempt resolves.
  #
  # `advise_meta` (attempt/ceiling/stage) rides in `opts` under
  # `:advise_meta`, NOT as a new positional arg to `advisor_fn/3` — the
  # `advisor_fn` seam's arity stays fixed (18 pre-existing
  # `no_op_advisor_fn()` test stubs depend on it; see pitch "the advisor is
  # handed a paragraph" D-10). `default_advisor_fn/3` reads it back out of
  # `opts` to fill packet section 4 (attempt/stage) via env vars passed to
  # `codegen-advise`.
  #
  # Suppressed under a fixed campaign binding (mirrors
  # `maybe_escalate_model/5`'s `resolve_fixed_binding` guard) — a
  # role-model-sweep arm measuring a fixed binding must not have its
  # evidence perturbed by advisor guidance either.
  #
  # A failed/unavailable advisor call is ADDITIVE-failure: ctx passes
  # through unchanged. Advice is help, never a gate.
  @type advise_meta :: %{
          optional(:stage) => String.t(),
          optional(:attempt) => pos_integer(),
          optional(:ceiling) => pos_integer(),
          optional(:repro_count) => non_neg_integer()
        }
  @spec maybe_advise(map(), String.t(), harness(), run_opts(), boolean(), advise_meta()) :: map()
  defp maybe_advise(ctx, dev_role, harness, opts, final_attempt?, advise_meta)

  defp maybe_advise(ctx, _dev_role, _harness, _opts, false, _advise_meta), do: ctx

  defp maybe_advise(ctx, dev_role, build_harness, opts, true, advise_meta) do
    resolve_harness_fn =
      Keyword.get(opts, :resolve_harness_fn, &RoleResolver.resolve_harness/2)

    harness = resolve_harness_fn.(dev_role, build_harness)

    if resolve_fixed_binding(dev_role, harness, opts) != :none do
      ctx
    else
      do_maybe_advise(ctx, harness, opts, advise_meta)
    end
  end

  defp do_maybe_advise(ctx, harness, opts, advise_meta) do
    advisor_fn = Keyword.get(opts, :advisor_fn, &default_advisor_fn/3)

    reason =
      get_in(ctx, [:artifacts, :last_failure_reason]) ||
        get_in(ctx, [:artifacts, :review_feedback]) || ""

    brief = get_in(ctx, [:artifacts, :rework_brief]) || ""

    context_text =
      "Build harness: #{harness}\n\n## Rework reason\n\n#{reason}\n\n## Rework brief\n\n#{brief}"

    call_opts = Keyword.put(opts, :advise_meta, Map.put(advise_meta, :final_attempt, true))

    case advisor_fn.(harness, context_text, call_opts) do
      {:ok, plan} when is_binary(plan) and plan != "" ->
        operator_note("advisor: diagnosis captured at give-up boundary")

        persist_advisor_exchange(ctx.cwd, context_text, plan, advise_meta)

        put_in(ctx, [:artifacts, :advisor_plan], plan)

      _ ->
        ctx
    end
  end

  # Writes `codegen/gate-pending/advisor-exchange.json` — a durable sidecar
  # recording the LATEST advisor question+answer pair, at the moment the
  # advisor returns (not routed through `run/1`'s `{:error, String.t()}`
  # return, which is a bare string with no room for a side payload and
  # whose shape ~40+ existing callers pattern-match on — see pitch "the
  # advisor is handed a paragraph" D-9/D-11 discussion). `park_failure/1`
  # reads this file (best-effort, optional) when parking a terminal failure
  # so the recovery dossier can carry the exchange without threading it
  # through the error value. Mirrors `write_terminal_marker/3`'s
  # write-to-disk-immediately idiom, but is BEST-EFFORT (a write failure
  # here never blocks or aborts the cycle — advice is additive, and losing
  # the sidecar loses only the dossier's copy of it, not the advisor call
  # itself, which already succeeded and is already in ctx.artifacts).
  @spec persist_advisor_exchange(String.t(), String.t(), String.t(), advise_meta()) :: :ok
  defp persist_advisor_exchange(cwd, context_text, plan_json, advise_meta) do
    dir = Path.join([cwd, "codegen", "gate-pending"])
    path = Path.join(dir, "advisor-exchange.json")

    diagnosis = decode_advisor_value(plan_json)

    payload =
      Jason.encode!(%{
        packet_digest: packet_digest(context_text),
        failure_signature: String.slice(context_text, 0, 500),
        stage: Map.get(advise_meta, :stage),
        attempt: Map.get(advise_meta, :attempt),
        ceiling: Map.get(advise_meta, :ceiling),
        diagnosis: diagnosis["diagnosis"],
        falsifier: diagnosis["falsifier"],
        next_probe: diagnosis["next_probe"],
        confidence: diagnosis["confidence"],
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, payload) do
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  @spec packet_digest(String.t()) :: String.t()
  defp packet_digest(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  # Best-effort JSON decode of the advisor's returned value — `plan_json` is
  # ALREADY schema-validated by `codegen-call`'s `--json-schema` enforcement
  # before it ever reaches this function, so a decode failure here means the
  # advisor call's own guarantee was violated somewhere between processes;
  # treat as "no structured fields available" rather than crash the cycle
  # over an observability sidecar.
  @spec decode_advisor_value(String.t()) :: map()
  defp decode_advisor_value(plan_json) do
    case Jason.decode(plan_json) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  # Real `:advisor_fn` — shells `codegen-advise`, resolved relative to this
  # repo's own root (mirrors how the loop shells other codegen-* binaries).
  # `System.cmd/3` has no stdin-piping option, so the context is written to a
  # temp file and passed as `--context @<path>` (the same `@`-path
  # convention `codegen-call`/`codegen-advise` already use elsewhere).
  # `--cwd=<ctx-cwd>` is REQUIRED by `codegen-advise` (see pitch D-9) so the
  # packet assembler collects git/gate state from the ACTUAL project being
  # built, not this repo's own `test_harness/` (the loop's own shell cwd —
  # see pitch ledger probe #17). Attempt/ceiling/stage metadata rides as env
  # vars (`CODEGEN_ADVISE_ATTEMPT`/`_CEILING`/`_STAGE`/`_FINAL_ATTEMPT`/
  # `_REPRO_COUNT`) which `codegen-advise`'s packet section 4 reads.
  # Returns `{:ok, plan_json}` on a clean advisor call, `:error` on ANY
  # non-zero exit, unreadable stdout, or temp-file write failure — the
  # caller (`do_maybe_advise/2`) treats `:error` as a no-op, never a crash:
  # advice is additive.
  #
  # Unlike `default_rework_brief_fn/1` (shells `git`, free/local/hermetic)
  # or `RoleResolver.resolve_escalation/2` (a pure `config.yaml` read, also
  # free), this default shells a REAL advisor LLM call — a
  # genuinely costly, non-hermetic side effect. `mix test --exclude slow` is
  # the hermetic gate and must never place a real LLM call; the ~40+
  # pre-existing give-up-boundary tests in `orchestration_loop_test.exs`
  # (added before this seam existed, several via the same escalation
  # give-up boundary this mirrors) cannot all be feasibly and durably kept
  # in sync with a NEW required mock, so this default fails closed
  # (`:error`, i.e. no-op — advice is additive by design) in `Mix.env() ==
  # :test`. Real builds (`mix codegen.loop`, MIX_ENV=prod/dev) are
  # unaffected — this branch never fires there.
  @spec default_advisor_fn(harness(), String.t(), run_opts()) :: {:ok, String.t()} | :error
  def default_advisor_fn(harness, context_text, opts) do
    if Mix.env() == :test do
      :error
    else
      do_default_advisor_fn(harness, context_text, opts)
    end
  end

  defp do_default_advisor_fn(harness, context_text, opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    advise_meta = Keyword.get(opts, :advise_meta, %{})

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "codegen-advise-context-#{System.unique_integer([:positive])}.txt"
      )

    env = advise_meta_env(advise_meta)

    try do
      case File.write(tmp_path, context_text) do
        :ok ->
          case System.cmd(
                 @codegen_advise_bin,
                 ["--harness=#{harness}", "--cwd=#{cwd}", "--context=@#{tmp_path}"],
                 stderr_to_stdout: false,
                 env: env
               ) do
            {out, 0} ->
              trimmed = String.trim(out)
              if trimmed == "", do: :error, else: {:ok, trimmed}

            {_out, _status} ->
              :error
          end

        {:error, _reason} ->
          :error
      end
    after
      File.rm(tmp_path)
    end
  rescue
    _ -> :error
  end

  # Translates `advise_meta` into the `CODEGEN_ADVISE_*` env vars
  # `codegen-advise`'s packet section 4 reads. Absent keys are simply
  # omitted (the packet renders "unavailable" for them, per its own
  # explicit-absence contract) — never a fabricated 0/false default.
  @spec advise_meta_env(advise_meta()) :: [{String.t(), String.t()}]
  defp advise_meta_env(advise_meta) do
    [
      {"CODEGEN_ADVISE_STAGE", Map.get(advise_meta, :stage)},
      {"CODEGEN_ADVISE_ATTEMPT", Map.get(advise_meta, :attempt)},
      {"CODEGEN_ADVISE_CEILING", Map.get(advise_meta, :ceiling)},
      {"CODEGEN_ADVISE_FINAL_ATTEMPT", Map.get(advise_meta, :final_attempt)},
      {"CODEGEN_ADVISE_REPRO_COUNT", Map.get(advise_meta, :repro_count)}
    ]
    |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, to_string(v)} end)
  end

  # A witness (or, absent that, the raw gate log) naming a path under
  # `context/*.md` or `PROJECT_CONTEXT.md` names a check only the
  # context-curator can satisfy — the committer cannot Read/Edit those
  # paths (subagent-read-discipline denies it), so routing that failure to
  # the developer would be a guaranteed-exhaust dead end (see
  # `curator_doc_check_exhausted/3`, the sibling check that already reaches
  # this same conclusion for the curator's OWN dedicated scan step).
  @curator_owned_signatures [
    ~r{\bcontext/[A-Za-z0-9_-]+\.md\b},
    ~r{\bPROJECT_CONTEXT\.md\b}
  ]

  # Dispatches the `:gate_classify_fn` test seam; defaults to reading
  # `gate-run.log` (the same file `gate_failure_reason/1` reads) through
  # `LoopGate.classify_failure/1` for the infra/code split, then narrowing
  # a `:code` verdict to its OWNING role: a context-doc-shaped witness ->
  # `context-curator`, everything else -> `dev_role` (the cycle's own
  # developer — today's behavior, preserved for every unmapped check).
  @spec default_gate_classify_fn(String.t(), String.t()) ::
          LoopGate.owner_class() | :stale_build
  defp default_gate_classify_fn(cwd, dev_role) do
    log_path = Path.join([cwd, "codegen", "gate-pending", "gate-run.log"])

    content =
      case File.read(log_path) do
        {:ok, content} -> content
        {:error, _reason} -> ""
      end

    cond do
      LoopGate.stale_build?(content) ->
        :stale_build

      true ->
        case LoopGate.classify_failure(content) do
          :infra ->
            :infra

          :code ->
            {:owner, resolve_gate_owner(cwd, dev_role)}
        end
    end
  end

  # Resolves which role owns a `:code`-classified gate failure. Prefers the
  # located witness (`LoopGate.failing_check/1`, the same `file:line —
  # cause` text the Witness Discipline rule already threads to the
  # developer's rework prompt) over the raw gate log — the witness is
  # scoped to the EXACT located failure, so the owner-mapping regex never
  # false-matches on incidental context-doc mentions elsewhere in a long
  # log. Falls back to `dev_role` (today's behavior) when the witness is
  # empty or matches no known owner signature.
  @spec resolve_gate_owner(String.t(), String.t()) :: String.t()
  defp resolve_gate_owner(cwd, dev_role) do
    witness = LoopGate.failing_check(cwd)

    if witness != "" and Enum.any?(@curator_owned_signatures, &Regex.match?(&1, witness)) do
      "context-curator"
    else
      dev_role
    end
  end

  # Reads the full gate-run.log written by LoopGate.run_gate/2 (via
  # gate-result.sh's write_gate_result) so a developer re-invocation carries
  # the real red output, not just a terse "gate verdict=failed" reason. Falls
  # back to the terse reason when the log is absent/unreadable (e.g. mocked
  # gate_fn test overrides that never write a real log file).
  defp gate_failure_reason(cwd) do
    log_path = Path.join([cwd, "codegen", "gate-pending", "gate-run.log"])

    case File.read(log_path) do
      {:ok, content} ->
        "gate verdict=failed\n\n" <> content

      # fail-loud-exempt: a missing/unreadable gate-run.log is a legitimate
      # "no full log to fold in" case (mocked gate_fn test overrides never
      # write a real log file; a real loop run always writes one via
      # LoopGate.run_gate/2). Falls back to the terse reason string.
      {:error, _reason} ->
        "gate verdict=failed"
    end
  end

  # Content-hash of the tracked+untracked working tree (excluding gitignored
  # paths) -- used as a progress signal for gate-retry bounding. Returns ""
  # when `cwd` is not a git work tree (synthetic/non-git cwd -- only mocked
  # unit tests use such a cwd; a real loop run always operates inside the
  # scaffolded project's git repo).
  @spec tree_signature(String.t()) :: String.t()
  def tree_signature(cwd) do
    if git_work_tree?(cwd) do
      script =
        "git ls-files -oc --exclude-standard | sort | " <>
          "xargs shasum 2>/dev/null | shasum | cut -d' ' -f1"

      case System.cmd("bash", ["-c", script], stderr_to_stdout: true, cd: cwd) do
        {output, 0} ->
          String.trim(output)

        # fail-loud-exempt: git-dir check above already confirmed `cwd` is a
        # real git work tree; a non-zero exit here means shasum/xargs/sort
        # are unavailable — a legitimate "no signature available" case
        # do_gate_loop/9 falls back to the count-based bound for.
        _other ->
          ""
      end
    else
      ""
    end
  end

  # True when `cwd` is a real git work tree (existing dir with a resolvable
  # git-dir) — the pre-check `tree_signature/1` needs because the shell
  # pipeline's own exit code reflects only its LAST stage (`cut`), which
  # exits 0 even when `git ls-files` failed upstream on a non-git cwd.
  defp git_work_tree?(cwd) do
    File.dir?(cwd) and
      match?(
        {_out, 0},
        System.cmd("git", ["-C", cwd, "rev-parse", "--git-dir"], stderr_to_stdout: true)
      )
  end

  # Diff embed cap: above this many bytes the brief switches from the
  # verbatim diff to `--stat` + a scoped-read instruction (see plan/pitch
  # "Size bound" — observed cycle diffs run 35.6 KB typical, 111 KB worst).
  @rework_brief_max_bytes 40_000

  # Header-neutral working-tree diff capture, shared by the developer's
  # rework brief (`default_rework_brief_fn/1`) and the reviewer's
  # `## Diff under review` block (pitch "hand each role the material its
  # job needs"). `default_rework_brief_fn/1` used to inline this capture
  # with its OWN second-person framing baked into the returned string
  # ("### Your current diff (uncommitted, authoritative)") — false in a
  # reviewer's voice, so the capture is split out and each caller supplies
  # its own header/instruction text. Returns
  # `{diff_trimmed, untracked, diff_out_byte_size, diff_args, oversized?}` —
  # every value a caller needs to render either the verbatim body or the
  # `--stat` degrade, without re-shelling anything. `diff_trimmed` and
  # `untracked` are both "" when nothing changed (non-git cwd handled by
  # the caller via `git_work_tree?/1`, exactly as before).
  @spec capture_working_tree_diff(String.t(), keyword()) ::
          {String.t(), String.t(), non_neg_integer(), [String.t()], boolean()}
  defp capture_working_tree_diff(cwd, opts \\ []) do
    base_head = cycle_base_head(cwd)
    diff_args = if base_head, do: ["diff", "HEAD"], else: ["diff"]

    {diff_out, _status} =
      System.cmd("git", diff_args, cd: cwd, stderr_to_stdout: true)

    {status_out, _status} =
      System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true)

    untracked =
      status_out
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "??"))
      |> Enum.join("\n")

    diff_trimmed = String.trim(diff_out)
    max_bytes = Keyword.get(opts, :max_bytes, @rework_brief_max_bytes)

    {diff_trimmed, untracked, byte_size(diff_out), diff_args, byte_size(diff_out) > max_bytes}
  end

  # Captures the developer's uncommitted working-tree diff for a rework
  # re-entry (structural gap: gate-red / reviewer CHANGES_REQUESTED / env-var
  # violation). This is the compressed form of the work already done — the
  # re-entering developer should repair the named fault, not re-derive its
  # own diff turn-by-turn via `git diff`/`Read`. Returns "" when `cwd` is not
  # a real git work tree (synthetic/mocked test cwd) or the tree is clean
  # (nothing to embed) -- both are legitimate "no brief" cases build_prompt/2
  # renders nothing for.
  @spec default_rework_brief_fn(String.t()) :: String.t()
  def default_rework_brief_fn(cwd) do
    if git_work_tree?(cwd) do
      {diff_trimmed, untracked, diff_out_size, diff_args, oversized?} =
        capture_working_tree_diff(cwd)

      cond do
        diff_trimmed == "" and untracked == "" ->
          ""

        oversized? ->
          {stat_out, _status} =
            System.cmd("git", diff_args ++ ["--stat"], cd: cwd, stderr_to_stdout: true)

          "### Your current diff (uncommitted, authoritative) — TOO LARGE TO INLINE\n\n" <>
            "Diff is #{diff_out_size} bytes — too large to inline. Run " <>
            "`git #{Enum.join(diff_args, " ")} -- <path>` for the specific files named in " <>
            "the fault below; do not sweep the tree.\n\n" <>
            "```\n" <>
            String.trim(stat_out) <>
            "\n```\n\n" <>
            "### Untracked files\n\n```\n" <> untracked <> "\n```"

        true ->
          "### Your current diff (uncommitted, authoritative)\n\n" <>
            "```diff\n" <>
            diff_trimmed <>
            "\n```\n\n" <>
            "### Untracked files\n\n```\n" <> untracked <> "\n```"
      end
    else
      ""
    end
  end

  # Reviewer's `## Diff under review` capture (move 1 of pitch "hand each
  # role the material its job needs"): the SAME git idiom and SAME
  # @rework_brief_max_bytes degrade as the developer's rework brief, but
  # header-neutral — "authoritative, this is YOUR work" is false in a
  # reviewer's voice. Also returns the per-path `sha256` digest map AND
  # per-path diff body map move 2 needs to compute + render a re-review
  # delta, so `invoke_reviewer/4` shells `git` exactly once per pass
  # regardless of which blocks end up rendered. Digests/bodies are keyed on
  # the file path as reported by `git diff --name-only` + `git status
  # --porcelain` (bounded to the SAME max_bytes cap as the whole-tree
  # capture — a single oversized path degrades to its own byte count
  # rather than blowing the digest map's memory).
  @spec default_review_diff_fn(String.t()) ::
          {String.t(), %{String.t() => String.t()}, %{String.t() => String.t()}}
  def default_review_diff_fn(cwd) do
    if git_work_tree?(cwd) do
      {diff_trimmed, untracked, diff_out_size, diff_args, oversized?} =
        capture_working_tree_diff(cwd)

      {digests, bodies} = per_path_diff_digests(cwd, diff_args)

      block =
        cond do
          diff_trimmed == "" and untracked == "" ->
            ""

          oversized? ->
            {stat_out, _status} =
              System.cmd("git", diff_args ++ ["--stat"], cd: cwd, stderr_to_stdout: true)

            "TOO LARGE TO INLINE\n\n" <>
              "Diff is #{diff_out_size} bytes — too large to inline. Run " <>
              "`git #{Enum.join(diff_args, " ")} -- <path>` for the specific files you need " <>
              "to inspect; do not sweep the tree.\n\n" <>
              "```\n" <>
              String.trim(stat_out) <>
              "\n```\n\n" <>
              "### Untracked files\n\n```\n" <> untracked <> "\n```"

          true ->
            "```diff\n" <>
              diff_trimmed <>
              "\n```\n\n" <>
              "### Untracked files\n\n```\n" <> untracked <> "\n```"
        end

      {block, digests, bodies}
    else
      {"", %{}, %{}}
    end
  end

  # Per-path digest map for the re-review delta (move 2): one sha256 per
  # changed path, computed from the loop's own `git diff` bytes — never
  # from the developer's typed `files_modified` event, which is
  # model-authored and must not be the source of a deterministic claim
  # (pitch D4). Both tracked (`git diff --name-only`) and untracked
  # (`git status --porcelain`) paths are included so a brand-new file
  # counts as "changed since last review" too. Also returns the per-path
  # diff BODY (not just its digest) so `since_last_review_section/1` can
  # render the changed paths' diff blocks verbatim without a second `git`
  # shell-out.
  @spec per_path_diff_digests(String.t(), [String.t()]) ::
          {%{String.t() => String.t()}, %{String.t() => String.t()}}
  defp per_path_diff_digests(cwd, diff_args) do
    name_only_args =
      Enum.map(diff_args, fn
        "diff" -> "diff"
        other -> other
      end) ++ ["--name-only"]

    {tracked_out, _status} = System.cmd("git", name_only_args, cd: cwd, stderr_to_stdout: true)

    {status_out, _status} =
      System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true)

    untracked_paths =
      status_out
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "??"))
      |> Enum.map(&String.trim_leading(&1, "?? "))

    tracked_paths = String.split(tracked_out, "\n", trim: true)

    per_path =
      (tracked_paths ++ untracked_paths)
      |> Enum.uniq()
      |> Map.new(fn path ->
        {out, _status} =
          System.cmd("git", diff_args ++ ["--", path], cd: cwd, stderr_to_stdout: true)

        # Untracked paths produce no `git diff` output (nothing to diff
        # against) — fall back to the raw file content so a brand-new
        # file's digest (and rendered body) still changes across passes if
        # its content changes.
        body =
          if String.trim(out) == "" do
            case File.read(Path.join(cwd, path)) do
              {:ok, content} -> content
              {:error, _reason} -> ""
            end
          else
            out
          end

        digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

        {path, {digest, body}}
      end)

    digests = Map.new(per_path, fn {path, {digest, _body}} -> {path, digest} end)
    bodies = Map.new(per_path, fn {path, {_digest, body}} -> {path, body} end)

    {digests, bodies}
  end

  # Dispatches the `:rework_brief_fn` test seam; defaults to the real shelled
  # capture. Called at each of the three developer rework re-entry sites
  # (review CHANGES_REQUESTED, env-var violation, gate red) so the brief is
  # captured fresh at the moment of re-entry -- not stashed once at cycle
  # start, where it would be stale by the time a later re-entry fires.
  defp capture_rework_brief(cwd, opts) do
    brief_fn = Keyword.get(opts, :rework_brief_fn, &default_rework_brief_fn/1)
    brief_fn.(cwd)
  end

  # Loop-derived changed-file LIST (not a diff) for the reviewer's
  # `## Files Modified` section — the file set was the actual gap in the
  # reviewer prompt (see pitch "reviewer handoff names the files under
  # review"); content is one allowed `git diff HEAD -- <path>` away.
  # Mirrors default_rework_brief_fn/1's git idiom (unborn-HEAD fallback,
  # non-git cwd -> ""). Returns "" when there is nothing changed (non-git
  # cwd, or a real git tree with a clean status) -- build_prompt/2 renders
  # no section for either case.
  @spec default_review_file_set_fn(String.t()) :: String.t()
  def default_review_file_set_fn(cwd) do
    if git_work_tree?(cwd) do
      base_head = cycle_base_head(cwd)

      diff_args =
        if base_head, do: ["diff", "--name-only", "HEAD"], else: ["diff", "--name-only"]

      {tracked_out, _status} = System.cmd("git", diff_args, cd: cwd, stderr_to_stdout: true)

      {status_out, _status} =
        System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true)

      untracked =
        status_out
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "??"))
        |> Enum.map(&String.trim_leading(&1, "?? "))

      (String.split(tracked_out, "\n", trim: true) ++ untracked)
      |> Enum.uniq()
      |> Enum.join("\n")
    else
      ""
    end
  end

  # A verifier surface is anything that can change whether the gate/grader
  # itself is capable of catching a defect: test files, the loop's own gate
  # module and its tests, the bash gate contracts, the enforcement registry
  # + compiled hooks, and CI/gate Makefile wiring. Move C ("surface verifier
  # edits to the reviewer — do not forbid them") from the pitch this
  # implements: this is a CLASSIFY-and-SURFACE, never a deny — the reviewer
  # decides, same as any other change; the notice only ensures a self-edit
  # to the grader is never invisible in the diff the reviewer is handed.
  @verifier_path_patterns [
    ~r{(^|/)test/.*_test\.exs$},
    ~r{(^|/)test/.*_test\.exe?x?s$},
    ~r{_test\.sh$},
    ~r{(^|/)loop_gate\.ex$},
    ~r{(^|/)gate-result\.sh$},
    ~r{(^|/)gate-select\.sh$},
    ~r{(^|/)shared/enforcement/registry\.yaml$},
    ~r{(^|/)shared/enforcement/enforcement_compiler\.py$},
    ~r{(^|/)Makefile$},
    ~r{gate-config\.sh$}
  ]

  # Classifies the loop-derived changed-file set (the SAME value already
  # rendered under `## Files Modified` — no second file walk, no new git
  # call) against `@verifier_path_patterns`. Empty `files` (nothing
  # changed, or non-git cwd) yields no notice. Purely additive prose; never
  # blocks, never denies — see the moduledoc note on this section.
  @spec verifier_surface_notice(String.t()) :: String.t()
  defp verifier_surface_notice(files) when is_binary(files) do
    touched =
      files
      |> String.split("\n", trim: true)
      |> Enum.filter(fn path ->
        Enum.any?(@verifier_path_patterns, &Regex.match?(&1, path))
      end)

    if touched == [] do
      ""
    else
      "\n\n## Verifier Surface Touched\n\n" <>
        "This cycle's diff edits the gate/grader itself (test files, the loop's gate " <>
        "module, the bash gate contracts, the enforcement registry, or gate/CI wiring), " <>
        "not just the feature under test:\n\n" <>
        "```\n" <>
        Enum.join(touched, "\n") <>
        "\n```\n\n" <>
        "This is legitimate roughly half the time (fixing a broken test, wiring a new " <>
        "gate check). Scrutinize it explicitly: does this change make the gate MORE able " <>
        "to catch a defect, or does it weaken/relax what the gate can detect? Flag " <>
        "`CHANGES_REQUESTED` if a test assertion was loosened, deleted, or its evidence " <>
        "source replaced with a constant/no-op without a stated reason in the diff."
    end
  end

  # Move 2 (pitch "hand each role the material its job needs"): on a
  # re-review pass, renders the delta since THIS reviewer's own last pass
  # (the exact paths whose diff changed, verbatim — taken from the capture
  # already in `ctx.artifacts.review_diff_bodies`, no new git call), the
  # verdict text that pass returned (`ctx.artifacts.review_feedback`,
  # already written by `handle_review/7` before the rework — this is the
  # SAME value the re-entering developer already gets, now also handed to
  # the re-invoked reviewer standing next to it), and a terminality notice
  # naming the pass number and the budget. Renders nothing on a first pass
  # (`review_diff_delta` is stashed only when a prior digest map existed —
  # see `invoke_reviewer/4`) — the normal case, not an error.
  @spec since_last_review_section(map()) :: String.t()
  defp since_last_review_section(ctx) do
    delta = get_in(ctx, [:artifacts, :review_diff_delta])

    if is_list(delta) do
      bodies = get_in(ctx, [:artifacts, :review_diff_bodies]) || %{}
      feedback = get_in(ctx, [:artifacts, :review_feedback]) || ""
      pass_number = get_in(ctx, [:artifacts, :review_pass_number])
      max_passes = get_in(ctx, [:artifacts, :review_max_passes])

      changed_block =
        if delta == [] do
          "No path's diff changed since your last pass (the rework may have addressed your " <>
            "finding with a change too small to alter these files, or targeted a different " <>
            "file than the ones you reviewed)."
        else
          Enum.map_join(delta, "\n\n", fn
            {path, :removed} ->
              "### #{path} (removed since your last pass)\n\nThis path no longer differs from " <>
                "HEAD — the rework reverted it."

            {path, kind} ->
              body = Map.get(bodies, path, "")

              "### #{path} (#{kind})\n\n```diff\n" <> String.trim(body) <> "\n```"
          end)
        end

      terminal_notice =
        if is_integer(pass_number) and is_integer(max_passes) do
          if pass_number >= max_passes do
            "\n\nThis is review pass #{pass_number} of #{max_passes} — the review re-work " <>
              "budget is exhausted. A `REVIEW_VERDICT: CHANGES_REQUESTED` here ends the " <>
              "build with no further rework."
          else
            "\n\nThis is review pass #{pass_number} of #{max_passes}."
          end
        else
          ""
        end

      "\n\n## Since your last review\n\n" <>
        "### Your prior finding\n\n" <>
        feedback <>
        "\n\n### What changed since then\n\n" <>
        changed_block <>
        terminal_notice
    else
      ""
    end
  end

  # Single reviewer-invocation seam (first pass in run_roles/4 AND re-review
  # in handle_review/7 both route here) so no entry path can ship a reviewer
  # prompt without the loop-derived ## Files Modified set -- the gap that
  # made a reviewer refuse a gate-green cycle (pitch "reviewer handoff names
  # the files under review"). Captures the set FRESH at each call (a
  # re-review runs against a newer tree than the first pass). An empty set
  # in a REAL git tree means the cycle produced nothing to review -- fail
  # loud rather than hand the reviewer an empty scope, mirroring
  # verify_committed!/2's existing dirty/empty guards. Non-git cwd (mocked
  # unit tests) yields "" and skips the refusal.
  #
  # Also captures the reviewer's diff-under-review + per-path digest map
  # (pitch "hand each role the material its job needs", moves 1-2): the
  # digest map from the PREVIOUS pass (stashed at
  # `ctx.artifacts.review_diff_digests`, absent on pass 1) is compared to
  # the freshly captured one, yielding the set of paths whose diff bytes
  # changed since this reviewer's own last pass -- the re-review delta.
  # `ctx.artifacts.review_diff` / `review_diff_digests` are updated on
  # EVERY pass (pass 1 has no prior digests to diff against, so the delta
  # is simply absent -- build_prompt/2 renders no `## Since your last
  # review` block for a first pass).
  defp invoke_reviewer(reviewer_role, harness, ctx, opts) do
    set_fn = Keyword.get(opts, :review_file_set_fn, &default_review_file_set_fn/1)
    files = set_fn.(ctx.cwd)

    if files == "" and git_work_tree?(ctx.cwd) do
      {:error, "cycle produced no changes — nothing for the reviewer to review"}
    else
      diff_fn = Keyword.get(opts, :review_diff_fn, &default_review_diff_fn/1)
      {diff_block, digests, bodies} = diff_fn.(ctx.cwd)

      prior_digests = get_in(ctx, [:artifacts, :review_diff_digests])

      ctx =
        ctx
        |> put_in([:artifacts, :review_file_set], files)
        |> put_in([:artifacts, :review_diff], diff_block)
        |> put_in([:artifacts, :review_diff_digests], digests)
        |> put_in([:artifacts, :review_diff_bodies], bodies)
        |> then(fn c ->
          if is_map(prior_digests) do
            changed_paths = diff_delta(prior_digests, digests)
            put_in(c, [:artifacts, :review_diff_delta], changed_paths)
          else
            c
          end
        end)

      with {:ok, result} <- invoke_with_retry(reviewer_role, harness, ctx, opts) do
        {:ok, result, ctx}
      end
    end
  end

  # Computes the set of paths whose diff digest changed between two
  # reviewer passes: added (new key), removed (key present before, absent
  # now -- e.g. a rework that reverted a file), or changed (same key,
  # different digest). Returns "" when nothing changed (identical digest
  # maps) so build_prompt/2 can render no delta block for a no-op re-review
  # (the :unknown-verdict re-invocation path, which reruns the SAME
  # reviewer with no developer rework in between).
  @spec diff_delta(%{String.t() => String.t()}, %{String.t() => String.t()}) :: [
          {String.t(), :added | :removed | :changed}
        ]
  defp diff_delta(prior, current) do
    added =
      current
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(prior, &1))
      |> Enum.map(&{&1, :added})

    removed =
      prior
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(current, &1))
      |> Enum.map(&{&1, :removed})

    changed =
      current
      |> Enum.filter(fn {path, digest} -> Map.get(prior, path) not in [nil, digest] end)
      |> Enum.map(fn {path, _digest} -> {path, :changed} end)

    (added ++ removed ++ changed) |> Enum.sort_by(fn {path, _} -> path end)
  end

  # Runs `mix format`/`make format` in `cwd` as an explicit loop step. This
  # replaces the deleted SubagentStop fix-up hooks (curator-format,
  # post-developer-format) that used to auto-format the diff — under the
  # loop, roles run as main-agent `codegen-call` invocations with no
  # SubagentStop event, so formatting must be driven explicitly here.
  # Non-fatal: a missing/failing formatter must not crash the whole cycle
  # (the gate itself will surface unformatted-code failures if relevant).
  defp run_format_step(cwd, opts) do
    format_fn = Keyword.get(opts, :format_fn, &default_format_fn/1)
    format_fn.(cwd)
    :ok
  end

  defp default_format_fn(cwd) do
    if File.exists?(Path.join(cwd, "mix.exs")) and executable_on_path?("mix") do
      System.cmd("mix", ["format"], cd: cwd, stderr_to_stdout: true)
    end

    if File.exists?(Path.join(cwd, "Makefile")) and executable_on_path?("make") do
      System.cmd("make", ["format"], cd: cwd, stderr_to_stdout: true)
    end

    :ok
  end

  defp executable_on_path?(bin), do: !!System.find_executable(bin)

  # Advances codegen/gate-pending/cycle-state.json to `state` via
  # advance_cycle_state/6, threading the session id + active step log from
  # ctx/opts when present (empty string when absent — cycle-state.sh
  # tolerates "") and the cycle's own slug (opts[:slug], the same value the
  # loop uses to init its own cycle log) — this is what lets a future resume
  # attempt verify the checkpoint belongs to THIS pitch and not a foreign
  # one (see resume_checkpoint/3's identity guard).
  defp advance_cycle_state_step(state, ctx, opts) do
    advance_fn = Keyword.get(opts, :advance_cycle_state_fn, &advance_cycle_state/6)
    step_log = Keyword.get(opts, :step_log, Process.get(@log_path_key) || "")
    session_id = Keyword.get(opts, :session_id, Keyword.get(opts, :cycle_id) || "")
    slug = Keyword.get(opts, :slug) || ""
    verdict = if state == "GATED", do: "clear", else: ""

    advance_fn.(state, step_log, session_id, verdict, ctx.cwd, slug)
    :ok
  end

  # Invokes `role` once; on {:error, reason} retries exactly once with the
  # reason folded into context, then gives up. A first-attempt failure
  # (even when the retry recovers) stamps `--died interrupted` — the
  # `interrupted` kind is defined as "drop+respawn" (subagent_interruption.py
  # _KIND_WEIGHTS), i.e. it records a recovered drop, not only a fatal one.
  # A second failure (retry also failed, cycle halts) stamps `--died
  # aborted`. Both writes are fail-loud-non-blocking observability — a
  # failed `codegen-log append` write never changes the {:ok, _}/{:error, _}
  # returned here.
  defp invoke_with_retry(role, harness, ctx, opts) do
    invoke_fn = Keyword.get(opts, :invoke_fn, &invoke_role/4)
    # HEAD is sampled around the ENTIRE retry sequence (one sample pair per
    # invoke_with_retry/4 call, not per do_invoke_attempt/5 attempt) — see
    # record_and_assert_head_move!/5 below for the attribution + guard.
    pre_head = cycle_base_head(ctx.cwd)

    case do_invoke_attempt(role, harness, ctx, opts, invoke_fn, 1) do
      {:ok, _result} = ok ->
        post_head = cycle_base_head(ctx.cwd)
        record_and_assert_head_move!(role, ctx.cwd, pre_head, post_head, opts)
        ok

      other ->
        other
    end
  end

  # HEAD moved during this role's invocation (pre_head != post_head, both
  # non-nil — a real git tree). Records a `{"ev":"committed"}` event
  # (loop-authored, never role-authored) and asserts on the loop's OWN
  # pre/post samples — never on the recorded event itself, which a
  # bypassing role could forge via the codegen-log CLI.
  #
  # NO ROLE may move HEAD, unconditionally — `committer` left the role
  # vocabulary entirely (see pitch "committing is deterministic, not a
  # model call"); the ONLY thing that ever legitimately moves HEAD now is
  # `run_commit_step/3`'s `codegen-commit` shell-out, which is NOT a role
  # invocation and therefore never reaches `invoke_with_retry/4` (the sole
  # caller of this function) at all. Any role moving HEAD is a guard
  # bypass (see the three known incidents this reproduces as fixtures) —
  # raise loud, naming the role and the sha, so the cycle fails rather
  # than silently shipping an unattributed commit.
  #
  # nil sampling (non-git cwd, or unborn branch) short-circuits: nothing to
  # attribute, nothing to assert — mirrors cycle_base_head/1's own fail-open
  # posture for synthetic test cwds.
  @spec record_and_assert_head_move!(
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          run_opts()
        ) :: :ok
  defp record_and_assert_head_move!(_role, _cwd, nil, _post_head, _opts), do: :ok
  defp record_and_assert_head_move!(_role, _cwd, _pre_head, nil, _opts), do: :ok

  defp record_and_assert_head_move!(role, cwd, pre_head, post_head, opts)
       when pre_head != post_head do
    subject = git_commit_subject(cwd, post_head)
    log_committed(role, post_head, subject, opts)

    raise "OrchestrationLoop: HEAD moved during #{role} (#{post_head}); no role writes history " <>
            "— only the deterministic commit step does, and it is not a role invocation."
  end

  defp record_and_assert_head_move!(_role, _cwd, _pre_head, _post_head, _opts), do: :ok

  # `git log -1 --format=%s` for the commit subject at `sha`, in `cwd`. Empty
  # on any failure (never raises) — the subject is descriptive detail on the
  # committed event, not load-bearing for the assertion above.
  @spec git_commit_subject(String.t(), String.t()) :: String.t()
  defp git_commit_subject(cwd, sha) do
    case System.cmd("git", ["log", "-1", "--format=%s", sha], cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> ""
    end
  end

  # Writes a `{"ev":"committed",...}` event into THIS cycle's log (via
  # codegen-log committed --role <role> --sha <sha> --subject <subject>) —
  # see :log_committed_fn for the test seam and default_log_committed/5 for
  # the real writer.
  @spec log_committed(String.t(), String.t(), String.t(), run_opts()) :: :ok
  defp log_committed(role, sha, subject, opts) do
    log_committed_fn = Keyword.get(opts, :log_committed_fn, &default_log_committed/5)
    log_committed_fn.(role, sha, subject, Process.get(@log_path_key), opts)
  end

  # Default :log_committed_fn — shells `codegen-log committed --role <role>
  # --sha <sha> --subject <subject>` via CODEGEN_LOG_PATH. nil cycle_log (no
  # log initialized, e.g. most unit tests) -> silent no-op. A non-zero
  # codegen-log exit is fail-loud-non-blocking: prints to stderr, never
  # raises — this is an observability write, and the loop's own assertion
  # above (on its OWN samples) never depends on this write succeeding.
  @spec default_log_committed(String.t(), String.t(), String.t(), String.t() | nil, run_opts()) ::
          :ok
  defp default_log_committed(_role, _sha, _subject, nil, _opts), do: :ok

  defp default_log_committed(role, sha, subject, cycle_log, _opts) do
    unless File.exists?(@codegen_log_bin) do
      IO.puts(
        :stderr,
        "OrchestrationLoop: codegen-log not found at #{@codegen_log_bin} — committed not logged"
      )

      :ok
    else
      {output, exit_code} =
        System.cmd(
          @codegen_log_bin,
          ["committed", "--role", role, "--sha", sha, "--subject", subject],
          stderr_to_stdout: true,
          env: [{"CODEGEN_DIR", @codegen_dir}, {"CODEGEN_LOG_PATH", cycle_log}]
        )

      if exit_code != 0 do
        IO.puts(
          :stderr,
          "OrchestrationLoop: codegen-log committed failed (#{exit_code}): #{output}"
        )
      end

      :ok
    end
  end

  # One attempt. On failure the reason is classified against the shared
  # retryable taxonomy (LoopQueue.retryable_reason?/1):
  #
  #   * deterministic reason  -> @deterministic_attempts (2) total attempts,
  #     preserving the historical "failed twice" contract;
  #   * transient reason (transport fault, 5xx, overload, mid-response
  #     disconnect) -> up to @transient_attempts (4) total, with a backoff
  #     between them. A single "Connection closed mid-response" blip used to
  #     burn a whole build (both attempts landing inside the same bad window);
  #     an unattended overnight queue cannot afford that.
  #   * switch_model reason (the MODEL itself is unavailable/disabled/not
  #     found, LoopQueue.switch_model_reason?/1) -> classified BEFORE the
  #     transient/deterministic split above, since retrying the same dead
  #     model (either budget) is pointless. Walks the role's `fallback:`
  #     chain (RoleResolver.resolve_fallback/3) one rung per failure, each on
  #     a fresh cold session (switching models forfeits warm resume — the
  #     other model never saw the prior session). Chain exhausted -> fails
  #     loud naming every rung tried, never a silent downgrade to nothing.
  defp do_invoke_attempt(role, harness, ctx, opts, invoke_fn, attempt) do
    # Mint a session id for every COLD attempt-start — attempt 1 always, and
    # any later attempt that is starting fresh because the prior session
    # turned out unresumable (no :resume_session_id carried forward). This is
    # the id a transient retry resumes into. It is set here (not inside
    # invoke_role/4) so it survives even when the attempt drops before ever
    # reporting its own session id back (the whole point: the loop knows the
    # id up front instead of depending on a `result` event that a mid-response
    # kill never delivers). A resuming attempt (has :resume_session_id) keeps
    # the id it is about to resume as its own transport_session_id too, so a
    # SECOND drop on the resumed attempt resumes the same session again.
    ctx =
      case get_in(ctx, [:artifacts, :resume_session_id]) do
        nil -> put_in(ctx, [:artifacts, :transport_session_id], mint_session_id())
        sid -> put_in(ctx, [:artifacts, :transport_session_id], sid)
      end

    # Carry the retry index into the invocation so the per-role telemetry row
    # can state it. A retried call is a full second round-trip — one observed
    # reviewer retry cost 38 turns and $2.02 — and it was previously
    # indistinguishable from a first call in `cycle-summary.jsonl`.
    ctx = put_in(ctx, [:artifacts, :transport_attempt], attempt)

    case invoke_fn.(role, harness, ctx, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        switch_model? = LoopQueue.switch_model_reason?(reason)

        if switch_model? do
          handle_switch_model_failure(role, harness, ctx, opts, invoke_fn, attempt, reason)
        else
          do_invoke_attempt_non_model_failure(
            role,
            harness,
            ctx,
            opts,
            invoke_fn,
            attempt,
            reason
          )
        end
    end
  end

  # Walks one rung of the role's `fallback:` chain. `rung` is the NEXT rung
  # to try (0-indexed) — `ctx.artifacts.fallback_rung` tracks the last rung
  # tried, absent/nil on the first switch_model failure. Each rung's
  # {model, effort} rides `ctx.artifacts.escalated_model`, the exact seam
  # `invoke_role/4` already reads for give-up-boundary escalation — walking
  # the fallback chain and escalating on the final gate-retry attempt are
  # mutually exclusive per invocation (a role only ever has one active
  # override at a time), so sharing the seam is safe.
  defp handle_switch_model_failure(role, build_harness, ctx, opts, invoke_fn, attempt, reason) do
    resolve_fallback_fn =
      Keyword.get(opts, :resolve_fallback_fn, &RoleResolver.resolve_fallback/3)

    resolve_harness_fn =
      Keyword.get(opts, :resolve_harness_fn, &RoleResolver.resolve_harness/2)

    harness = resolve_harness_fn.(role, build_harness)

    rung = get_in(ctx, [:artifacts, :fallback_rung]) || 0
    rungs_tried = get_in(ctx, [:artifacts, :fallback_rungs_tried]) || []

    # Same suppression as `maybe_escalate_model/5`: a fixed campaign binding
    # must never be silently swapped for a fallback rung — the arm would end
    # up measuring an unrequested model. Report INCONCLUSIVE (via the normal
    # exhausted-fallback error path) instead of walking the chain.
    cond do
      resolve_fixed_binding(role, harness, opts) != :none ->
        log_died(role, "aborted", reason, opts)

        {:error,
         "role-model-sweep: #{role} binding fixed — #{reason} — fallback suppressed for campaign arm"}

      rung >= @max_fallback_rungs ->
        log_died(role, "aborted", reason, opts)
        {:error, fallback_exhausted_reason(role, reason, rungs_tried)}

      true ->
        case resolve_fallback_rung(role, harness, rung, opts, resolve_fallback_fn) do
          {model, effort} ->
            log_died(role, "interrupted", reason, opts)

            operator_note(
              "role #{role}: switching model — #{reason} — trying fallback rung #{rung}: #{model}/#{effort}"
            )

            retry_ctx =
              ctx
              |> put_in([:artifacts, :last_failure_reason], reason)
              |> put_in([:artifacts, :escalated_model], {model, effort})
              |> put_in([:artifacts, :fallback_rung], rung + 1)
              |> put_in([:artifacts, :fallback_rungs_tried], rungs_tried ++ [{model, reason}])
              # Switching models forfeits warm resume — the other model never
              # saw the prior session; always start the next attempt cold.
              |> Map.update!(:artifacts, &Map.delete(&1, :resume_session_id))

            do_invoke_attempt(role, harness, retry_ctx, opts, invoke_fn, attempt + 1)

          :none ->
            log_died(role, "aborted", reason, opts)
            {:error, fallback_exhausted_reason(role, reason, rungs_tried)}
        end
    end
  end

  # Resolves rung `rung` of `role`'s fallback chain, honoring
  # `opts[:fallback_model_override]` (threaded from `codegen-build
  # --fallback-model=<m>` via `mix codegen.loop --fallback-model`) as rung 0
  # for EVERY role — a one-build override of config.yaml, per the pitch's
  # "prepend as rung 0" contract. When the override is set, config.yaml's own
  # list shifts down by one (rung 1 here reads config.yaml rung 0, etc.).
  # Absent override (the common case) -> unchanged, reads config.yaml
  # directly at `rung`.
  @spec resolve_fallback_rung(
          String.t(),
          harness(),
          non_neg_integer(),
          run_opts(),
          (String.t(), harness(), non_neg_integer() -> {String.t(), String.t()} | :none)
        ) :: {String.t(), String.t()} | :none
  defp resolve_fallback_rung(role, harness, rung, opts, resolve_fallback_fn) do
    case Keyword.get(opts, :fallback_model_override) do
      override when is_binary(override) and override != "" ->
        if rung == 0 do
          {_normal_model, normal_effort} =
            Keyword.get(opts, :resolve_fn, &RoleResolver.resolve_role/2).(role, harness)

          {override, normal_effort}
        else
          resolve_fallback_fn.(role, harness, rung - 1)
        end

      _ ->
        resolve_fallback_fn.(role, harness, rung)
    end
  end

  defp fallback_exhausted_reason(role, last_reason, rungs_tried) do
    tried_desc =
      case rungs_tried do
        [] ->
          "no fallback rungs configured"

        rungs ->
          rungs
          |> Enum.map(fn {model, reason} -> "#{model} (#{reason})" end)
          |> Enum.join(", ")
      end

    "role #{role} exhausted model fallback chain: #{tried_desc}; last error: #{last_reason}"
  end

  defp do_invoke_attempt_non_model_failure(role, harness, ctx, opts, invoke_fn, attempt, reason) do
    # A stale-session reason can ONLY be produced by a --resume against a
    # session this loop itself just minted (never a role's own doing), so
    # it is classified with the SAME budget as the transient failure that
    # caused the resume in the first place — it is a continuation of that
    # transient chain, not a new deterministic failure of the role.
    resuming? = not is_nil(get_in(ctx, [:artifacts, :resume_session_id]))
    stale? = resuming? and stale_session_reason?(reason)
    transient? = stale? or LoopQueue.retryable_reason?(reason)
    max_attempts = if transient?, do: @transient_attempts, else: @deterministic_attempts

    if attempt < max_attempts do
      log_died(role, "interrupted", reason, opts)
      retry_ctx = put_in(ctx, [:artifacts, :last_failure_reason], reason)
      # The budget is only decided once a failure has been classified, so it
      # is recorded from here (the retry path) rather than guessed up front.
      retry_ctx = put_in(retry_ctx, [:artifacts, :transport_attempt_max], max_attempts)

      # A transient drop resumes the SAME session on the next attempt —
      # unless the session itself turned out to be unresumable (never
      # persisted before the drop), in which case fall back to a fresh
      # cold attempt with a brand-new id rather than looping forever on
      # a session that will never exist.
      retry_ctx =
        if transient? and not stale? do
          put_in(
            retry_ctx,
            [:artifacts, :resume_session_id],
            ctx.artifacts.transport_session_id
          )
        else
          Map.update!(retry_ctx, :artifacts, &Map.delete(&1, :resume_session_id))
        end

      if transient? do
        sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)
        sleep_fn.(backoff_ms(attempt))
      end

      if transient? and not stale? do
        operator_note(
          "role #{role}: transport drop — resuming session #{ctx.artifacts.transport_session_id} (attempt #{attempt + 1}/#{max_attempts})"
        )
      end

      do_invoke_attempt(role, harness, retry_ctx, opts, invoke_fn, attempt + 1)
    else
      log_died(role, "aborted", reason, opts)

      if attempt == 2 do
        {:error, "role #{role} failed twice: #{reason}"}
      else
        {:error, "role #{role} failed after #{attempt} attempts: #{reason}"}
      end
    end
  end

  # Mints a fresh v4 uuid for a NEW (cold) session — no external dep; the
  # repo carries no uuid library (grepped: 0 hits). RFC 4122 v4: 16 random
  # bytes, patch the version nibble (byte 6 high nibble := 4) and the
  # variant bits (byte 8 top 2 bits := 10), then hex-format with dashes.
  @spec mint_session_id() :: String.t()
  defp mint_session_id do
    <<b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15>> =
      :crypto.strong_rand_bytes(16)

    b6 = Bitwise.bor(Bitwise.band(b6, 0x0F), 0x40)
    b8 = Bitwise.bor(Bitwise.band(b8, 0x3F), 0x80)

    bytes = <<b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15>>
    hex = Base.encode16(bytes, case: :lower)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = hex

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  # A resume against a session that never persisted (dropped before its
  # first write) reports this exact string in the claude envelope's
  # `error` field (via call-dispatch.sh's `.errors[0] // .message // .result`
  # extraction) — probed in the pitch's References §5/§18. This reason is
  # NOT in LoopQueue's retryable taxonomy, so it can never itself cause a
  # resume loop; it only tells do_invoke_attempt/6 to fall back to cold.
  @spec stale_session_reason?(String.t()) :: boolean()
  defp stale_session_reason?(reason) when is_binary(reason),
    do: String.contains?(reason, "No conversation found with session ID")

  defp stale_session_reason?(_), do: false

  # One stderr line per resumed attempt — operator visibility into an
  # absorbed transport drop, no cycle-log format change.
  @spec operator_note(String.t()) :: :ok
  defp operator_note(msg) do
    IO.puts(:stderr, msg)
    :ok
  end

  # Backoff between transient retries (ms), indexed by the attempt that just
  # failed. Beyond the list, the last value repeats. Jittered +/-20% so
  # parallel builds don't thunder-herd on recovery from a shared incident.
  defp backoff_ms(attempt) do
    delays = [15_000, 60_000, 120_000]
    base = Enum.at(delays, attempt - 1, List.last(delays))
    jitter(base)
  end

  # +/-20% jitter around a base delay (ms). :rand is process-seeded; no
  # explicit seed needed. base=0 returns 0 (never negative or division by 0).
  @spec jitter(non_neg_integer()) :: non_neg_integer()
  defp jitter(0), do: 0

  defp jitter(base_ms) when base_ms > 0 do
    spread = div(base_ms, 5)
    base_ms - spread + :rand.uniform(2 * spread + 1) - 1
  end

  # Writes a `{"ev":"died","kind":<kind>}` death stamp into THIS cycle's log
  # (via codegen-log append <role> --died <kind>) — see :log_died_fn for the
  # test seam and default_log_died/4 for the real writer. cause is truncated
  # by codegen-log itself; passed through verbatim here.
  @spec log_died(String.t(), String.t(), String.t(), run_opts()) :: :ok
  defp log_died(role, kind, cause, opts) do
    log_died_fn = Keyword.get(opts, :log_died_fn, &default_log_died/4)
    log_died_fn.(role, kind, cause, Process.get(@log_path_key))
  end

  # Default :log_died_fn — shells `codegen-log append <role> --died <kind>
  # --cause <cause>` via CODEGEN_LOG_PATH. nil cycle_log (no log
  # initialized, e.g. most unit tests) → silent no-op. A non-zero
  # codegen-log exit is fail-loud-non-blocking: prints to stderr, never
  # raises — this is an observability write, and the loop's retry/halt
  # control flow must never depend on it succeeding.
  @spec default_log_died(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  defp default_log_died(_role, _kind, _cause, nil), do: :ok

  defp default_log_died(role, kind, cause, cycle_log) do
    unless File.exists?(@codegen_log_bin) do
      IO.puts(
        :stderr,
        "OrchestrationLoop: codegen-log not found at #{@codegen_log_bin} — died not logged"
      )

      :ok
    else
      {output, exit_code} =
        System.cmd(@codegen_log_bin, ["append", role, "--died", kind, "--cause", cause],
          stderr_to_stdout: true,
          env: [{"CODEGEN_DIR", @codegen_dir}, {"CODEGEN_LOG_PATH", cycle_log}]
        )

      if exit_code != 0 do
        IO.puts(
          :stderr,
          "OrchestrationLoop: codegen-log append --died failed (#{exit_code}): #{output}"
        )
      end

      :ok
    end
  end

  @doc """
  Returns the durable per-role transcript path for `cycle_id` (nil → nil,
  no durable capture is possible without a cycle id), `cwd`, `seq`
  (1-based, zero-padded to 2 digits), and `role`:

      transcript_path("20260705_070557_slug", "/proj", 1, "developer-static")
      #=> "/proj/codegen/logging/20260705_070557_slug/01-developer-static.jsonl"
  """
  @spec transcript_path(String.t() | nil, String.t(), non_neg_integer(), String.t()) ::
          String.t() | nil
  def transcript_path(nil, _cwd, _seq, _role), do: nil

  def transcript_path(cycle_id, cwd, seq, role) do
    nn = seq |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join([cwd, "codegen", "logging", cycle_id, "#{nn}-#{role}.jsonl"])
  end

  @doc """
  Invokes one role via `RoleResolver.resolve_role/2` (model/effort only) →
  `codegen-call --agent <role>` (native agent identity — the installed
  `~/.claude/agents/<role>.md` supplies the system prompt and allowed tools;
  RoleResolver no longer resolves or writes a prompt file), parses the
  `{result: {status, value, reason, ...}}` envelope, and branches on
  `status`.

  On a warm-resume attempt (`ctx.artifacts.resume_session_id` set by
  `do_invoke_attempt/6`), sends `resume_prompt/1`'s short continuation
  instead of the full `build_prompt/2` pitch/plan, and threads
  `--resume=<id>` instead of `--session-id=<id>` to `codegen-call`.

  When `ctx.artifacts.escalated_model` is a `{model, effort}` tuple (set by
  `do_gate_loop_rework/9` or `rework_final_gate/5` on the FINAL retry a
  give-up boundary allows), that tuple is used verbatim in place of
  `resolve_fn.(role, harness)` — the one place a stuck build is worth paying
  for a stronger tier. Absent (the normal case) → unchanged `resolve_fn`
  lookup.

  `status`:
  - `"success"` → `{:ok, envelope["result"]}`
  - `"failed"` → `{:error, reason}` (reason from `result.reason`, or a
    generic message if absent)
  - anything else → raises (crash loud — unexpected envelope shape)
  """
  @spec invoke_role(String.t(), harness(), map(), run_opts()) ::
          {:ok, map()} | {:error, String.t()}
  def invoke_role(role, build_harness, ctx, opts) do
    resolve_fn = Keyword.get(opts, :resolve_fn, &RoleResolver.resolve_role/2)

    # Per-role harness override (config.yaml `.harness.<role>.harness`).
    # Resolved ONCE here and used for every downstream lookup this
    # invocation makes (model/effort resolution, the codegen-call --harness
    # flag, and the guard bundle default_codegen_call/12 picks from it) —
    # never the raw build-wide harness. Absent override -> build_harness
    # unchanged, byte-for-byte today's behavior.
    resolve_harness_fn =
      Keyword.get(opts, :resolve_harness_fn, &RoleResolver.resolve_harness/2)

    harness = resolve_harness_fn.(role, build_harness)

    cycle_id = Process.get(@cycle_id_key)
    seq = Process.get(@transcript_seq_key, 0) + 1
    Process.put(@transcript_seq_key, seq)
    transcript = transcript_path(cycle_id, ctx.cwd, seq, role)

    # Nth invocation of THIS role in THIS cycle. Counted here, in the one
    # function every logical role call passes through, so a transport retry
    # (which re-enters invoke_role/4) and a rework re-invocation are counted
    # the same way: both are round-trips somebody paid for.
    role_call_counts = Process.get(@role_call_count_key, %{})
    role_call = Map.get(role_call_counts, role, 0) + 1
    Process.put(@role_call_count_key, Map.put(role_call_counts, role, role_call))
    call_reason = call_reason(ctx, role, role_call)

    # Session identity for THIS attempt — minted/carried forward by
    # do_invoke_attempt/6 before invoke_fn is ever called. resume_session_id
    # present -> warm-resume a transient-retry attempt; absent ->
    # transport_session_id pins a NEW (cold) call so a future transient
    # retry can recover it even if this attempt drops before reporting its
    # own session id back.
    resume_session_id = get_in(ctx, [:artifacts, :resume_session_id])
    cold_session_id = get_in(ctx, [:artifacts, :transport_session_id])

    # Default threads ctx.cwd into the codegen-call so the role's agent runs IN
    # the project directory. dispatch.sh cd's to test_harness to run mix, so
    # WITHOUT this every role would edit the wrong directory (loop bug #3).
    # The /6 seam signature is preserved for test overrides. `role` is bound
    # into the closure and threaded to default_codegen_call as the new
    # trailing `agent` arg — native `claude --agent <role>` invocation.
    # session_id/resume ride the CLOSURE (not the /6 seam) — same pattern
    # already used for role/transcript.
    codegen_call_fn =
      Keyword.get(opts, :codegen_call_fn, fn h, m, e, sp, tools, pr ->
        default_codegen_call(
          ctx.cwd,
          h,
          m,
          e,
          sp,
          tools,
          pr,
          transcript,
          role,
          resume_session_id,
          cold_session_id,
          ctx.base_head
        )
      end)

    {{model, effort}, effort_source} =
      case resolve_fixed_binding(role, harness, opts) do
        {fixed_model, fixed_effort} ->
          {{fixed_model, fixed_effort}, :campaign}

        :none ->
          {base_model, base_effort, base_source} =
            case get_in(ctx, [:artifacts, :escalated_model]) do
              {escalated_model, escalated_effort} ->
                {escalated_model, escalated_effort, :escalation}

              _ ->
                {rf_model, rf_effort} = resolve_fn.(role, harness)
                {rf_model, rf_effort, :role_config}
            end

          case Keyword.get(opts, :effort_override) do
            override when is_binary(override) and override != "" ->
              {{base_model, override}, :build_override}

            _ ->
              {{base_model, base_effort}, base_source}
          end
      end

    prompt =
      if resume_session_id do
        resume_prompt(role)
      else
        build_prompt(role, ctx)
      end

    # No --system-prompt: the agent's identity (system prompt + tools) is
    # resolved natively by `claude --agent <role>` from the installed agent
    # .md, not by RoleResolver.
    envelope = codegen_call_fn.(harness, model, effort, nil, nil, prompt)

    accumulate_telemetry(role, envelope, %{
      harness: harness,
      model: model,
      effort: effort,
      source: effort_source,
      native_effort: native_effort_realization(harness, effort)
    })

    write_cycle_summary(cycle_id, ctx.cwd, role, seq, transcript, envelope, %{
      "call" => role_call,
      "call_reason" => call_reason,
      "transport_attempt" => get_in(ctx, [:artifacts, :transport_attempt]) || 1,
      "transport_attempt_max" => get_in(ctx, [:artifacts, :transport_attempt_max])
    })

    case envelope do
      %{"result" => %{"status" => "success"} = result} ->
        # `"transcript"` rides along for the same reason `"session_id"` does:
        # the caller cannot recompute it (seq lives in a process key that has
        # already advanced by the time a result is inspected). Its one
        # consumer today is `resolve_review/1`, which reads this stream-json
        # to recover a verdict the returned value dropped instead of paying
        # for a second reviewer call.
        case check_budget(opts) do
          :ok ->
            {:ok,
             result
             |> Map.put("session_id", envelope["session_id"])
             |> Map.put("transcript", transcript)}

          {:error, reason} ->
            {:error, reason}
        end

      %{"result" => %{"status" => "failed"} = result} ->
        {:error, result["reason"] || "role #{role} failed with no reason given"}

      other ->
        raise "OrchestrationLoop: unexpected codegen-call envelope for role #{role}: #{inspect(other)}"
    end
  end

  # Names the adapter-realized native control for a canonical effort value —
  # telemetry-only description of what call-dispatch.sh actually emits, never
  # itself passed as an argv/env value. Mirrors harnesses/claude/
  # call-dispatch.sh's effort-emission branches exactly: claude omits
  # `--effort` for `"off"` (relying on the ambient `MAX_THINKING_TOKENS=0`
  # already set by call-dispatch.sh) and passes `--effort <value>` otherwise.
  defp native_effort_realization("claude_code", "off"), do: "settings.MAX_THINKING_TOKENS=0"
  defp native_effort_realization("claude_code", effort), do: "--effort #{effort}"
  defp native_effort_realization(_harness, effort), do: "effort=#{effort}"

  # ── Per-cycle spend cap (`--max-budget-usd`, threaded via
  # `opts[:max_budget_usd]`) ──────────────────────────────────────────────
  # Checked AFTER the role that just ran has been accumulated into
  # telemetry (its cost is already committed to the API — killing mid-call
  # would save nothing), and BEFORE the next role is invoked. Absent cap
  # (`nil`, the default) -> always `:ok`, exactly today's behavior.
  @spec check_budget(run_opts()) :: :ok | {:error, String.t()}
  defp check_budget(opts) do
    case Keyword.get(opts, :max_budget_usd) do
      nil ->
        :ok

      cap when is_number(cap) ->
        spent = get_telemetry().cost_usd

        if spent >= cap do
          {:error,
           "spend cap reached: $#{:erlang.float_to_binary(spent * 1.0, decimals: 2)} spent >= " <>
             "$#{:erlang.float_to_binary(cap * 1.0, decimals: 2)} cap (--max-budget-usd)"}
        else
          :ok
        end
    end
  end

  @doc """
  The continuation prompt sent on a warm-resume transient retry — replaces
  the full pitch prompt `build_prompt/2` would otherwise re-send. The
  resumed session already carries the role's full identity, declared scope,
  and prior tool-call history; re-sending the pitch would waste tokens
  re-deriving context the transcript already has.
  """
  @spec resume_prompt(String.t()) :: String.t()
  def resume_prompt(_role) do
    "Your previous turn was cut off by a transport error. The session's history above is " <>
      "your own work. Continue from where you stopped; do not redo completed work. Finish " <>
      "and emit your result JSON."
  end

  # The `## Declared Scope` prompt section — the deterministic half of what
  # the retired `## Plan` block used to carry, rendered from the pitch's own
  # `scope:` frontmatter list. Heading and fenced-list shape are contracted
  # by `shared/rules/roles/{developer,reviewer}.md`; changing either is a
  # rules-and-prompt change, not a formatting tweak.
  @spec declared_scope_block([String.t()]) :: String.t()
  defp declared_scope_block(scope) do
    "## Declared Scope\n\n" <>
      "The pitch's `scope:` field names every file this build is expected to touch. " <>
      "This is the pitch's own declaration, not a forecast: a declared path your diff " <>
      "does not cover is an incomplete build, and a file you touch that is NOT declared " <>
      "here must be justified in your section body.\n\n" <>
      "```\n" <> Enum.join(scope, "\n") <> "\n```"
  end

  @doc false
  def build_prompt(role, ctx) do
    reason = get_in(ctx, [:artifacts, :last_failure_reason])

    base = ctx[:pitch] || ""

    # Thread the pitch's OWN declared file list to the developer AND the
    # reviewer, under the exact `## Declared Scope` heading their baked rules
    # contract on. This is the pitch's mandatory `scope:` frontmatter field,
    # parsed deterministically at cycle start (no model in the loop, no
    # forecast) and stashed at ctx.pitch_scope. It occupies the same prompt
    # slot the retired `## Plan` block did: the developer gets the
    # authoritative starting file set instead of re-deriving scope from prose,
    # and the reviewer gets back its MECHANICAL coverage check — every
    # declared path must appear in the developer's typed `files_modified`
    # event. The judgement half of review binds to the pitch body, which is
    # already `base` above.
    #
    # Absent for an ad-hoc literal pitch (no frontmatter to read), in which
    # case the prompt stays the raw pitch, unchanged, and the reviewer reports
    # the mechanical half `N/A`. A QUEUED pitch can never reach here without a
    # scope — `Mix.Tasks.Codegen.Loop.resolve_pitch_scope!/2` raises first.
    scope = Map.get(ctx, :pitch_scope)

    base =
      if (developer_role?(role) or reviewer_role?(role)) and is_list(scope) and scope != [] do
        base <> "\n\n" <> declared_scope_block(scope)
      else
        base
      end

    # On a rework re-entry (gate red / reviewer CHANGES_REQUESTED / env-var
    # violation), thread the developer's own uncommitted working-tree diff
    # ahead of the fault sections below. This is a repair, not a rebuild —
    # the diff is the compressed form of the work already done; without it
    # the re-entering developer burns turns re-deriving its own change via
    # `git diff`/`Read` (measured: ~30% of a rework's turns on a real cycle).
    brief = get_in(ctx, [:artifacts, :rework_brief])

    base =
      if developer_role?(role) and is_binary(brief) and String.trim(brief) != "" do
        base <>
          "\n\n## Repair brief — this is a repair, not a rebuild\n\n" <>
          "You wrote the diff below three minutes ago in this same cycle. The design is " <>
          "settled: the pitch above is unchanged and the approach was accepted. Do NOT " <>
          "re-explore the codebase, re-derive scope, or re-read files whose content is " <>
          "already in the diff. This is the uncommitted working tree — if something in it " <>
          "is not yours, it predates the cycle; leave it alone and fix only the fault named " <>
          "below, then re-verify.\n\n" <> brief
      else
        base
      end

    # On the FINAL rework attempt before give-up, thread the advisor's
    # diagnosis (`ctx.artifacts.advisor_plan` — set by
    # `maybe_advise/5`, the SAME give-up boundary `maybe_escalate_model/5`
    # already fires at). A separate, stronger-model advisor call examined a
    # machine-assembled evidence packet from this same stuck build and
    # returned a structured `{diagnosis, falsifier, next_probe, ...}`
    # object (raw JSON — the schema's fields ARE the render; no
    # re-summarization here).
    advisor_plan = get_in(ctx, [:artifacts, :advisor_plan])

    base =
      if (developer_role?(role) or reviewer_role?(role)) and is_binary(advisor_plan) and
           String.trim(advisor_plan) != "" do
        base <>
          "\n\n## Advisor — second opinion\n\n" <>
          "A separate advisor call examined a machine-assembled evidence packet for this " <>
          "final attempt and returned a diagnosis with a falsifier and a discriminating next " <>
          "probe. It may be wrong — read it, do not blindly follow it — but it is a " <>
          "genuinely different angle before the loop gives up.\n\n" <> advisor_plan
      else
        base
      end

    # Thread the resolved gate command (stashed at turn-0 preflight — see
    # run/1) into a self-verify instruction: under the loop the developer
    # runs the gate itself, in its own warm session, and fixes every red
    # (its own or inherited) before handing back. The `developer-no-self-gate`
    # hook permits progress-bounded gate runs while CODEGEN_LOOP=1.
    gate_command = get_in(ctx, [:artifacts, :gate_command])

    base =
      if developer_role?(role) and is_binary(gate_command) and String.trim(gate_command) != "" do
        base <>
          "\n\n## Gate — self-verify (you run this, in THIS session)\n\n" <>
          "Before handing back, run `#{gate_command}` yourself. A red gate is a FAILED " <>
          "build regardless of cause — fix EVERY red, yours OR inherited: stale render → " <>
          "`make install`; stale lock → `mix deps.get`; your own test/compile failures → " <>
          "fix them. Re-run `#{gate_command}` until it is GREEN, then stop. The loop's hook " <>
          "permits progress-bounded gate runs while CODEGEN_LOOP=1."
      else
        base
      end

    # A normal context-curator invocation happens only after the loop has
    # graded this exact tree and a reviewer has approved it. Say that
    # explicitly so the curator consumes the narrow typed-learning handoff
    # instead of re-running the developer's full gate. Turn-0 orientation
    # repair has neither a reviewer artifact nor a REVIEWED resume marker and
    # therefore must not receive this stage claim.
    reviewed? =
      is_map(get_in(ctx, [:artifacts, "reviewer-phoenix"])) or
        is_map(get_in(ctx, [:artifacts, "reviewer-static"])) or
        get_in(ctx, [:artifacts, :resume_state]) == "REVIEWED"

    base =
      if role == "context-curator" and reviewed? do
        base <>
          "\n\n## Stage contract — post-review context curation\n\n" <>
          "The loop gate already passed for this exact tree and the reviewer approved it. " <>
          "Consume only the cycle log's typed `ev:learned` events and route durable learnings " <>
          "within your curator write surface. MUST NOT run the full gate or test command. " <>
          "Targeted curator routing and factcheck checks are allowed. The loop owns formatting " <>
          "and curator scans, and will re-run the gate if your edits change the tree."
      else
        base
      end

    non_blocking_findings = get_in(ctx, [:artifacts, :review_non_blocking_findings])

    base =
      if role == "context-curator" and is_binary(non_blocking_findings) and
           String.trim(non_blocking_findings) != "" do
        base <>
          "\n\n## Reviewer non-blocking findings\n\n" <>
          "These findings did not require developer rework. Preserve any durable context " <>
          "learning within your write surface; do not turn them into a gate rerun.\n\n" <>
          non_blocking_findings
      else
        base
      end

    # Move 3 (pitch "hand each role the material its job needs"): the
    # curator's own routine input, `ev:learned` events, HANDED OVER instead
    # of reconstructed from source (measured: a real curator turn spent 15
    # Reads + 6 Bash calls, ZERO of which touched the cycle log, because
    # nothing handed it the events). Three distinct outcomes, three
    # distinct renderings — see LoopGate.curator_learnings/1 and D12; a
    # swallowed read error must never render identically to "nobody
    # learned anything".
    base =
      if role == "context-curator" do
        case get_in(ctx, [:artifacts, :curator_learnings]) do
          {{:ok, events}, log_path} when is_list(events) ->
            body =
              if events == [] do
                "No `ev:learned` events were recorded this cycle (log: `#{log_path}`)."
              else
                "The following `ev:learned` events were recorded this cycle " <>
                  "(log: `#{log_path}`):\n\n```\n" <> Enum.join(events, "\n") <> "\n```"
              end

            base <> "\n\n## Learnings to route\n\n" <> body

          {{:error, :unreadable}, log_path} ->
            base <>
              "\n\n## Learnings to route\n\n" <>
              "The cycle log at `#{log_path}` could not be read — its `ev:learned` events " <>
              "could not be recovered for this turn. This is NOT the same as an empty " <>
              "cycle; do not report a drop for learnings you could not see."

          {{:error, :absent}, _log_path} ->
            base <>
              "\n\n## Learnings to route\n\n" <>
              "No cycle log was initialized for this run — its `ev:learned` events could " <>
              "not be recovered for this turn. This is NOT the same as an empty cycle; do " <>
              "not report a drop for learnings you could not see."

          nil ->
            base
        end
      else
        base
      end

    # On a review re-work pass, thread the reviewer's feedback to the developer.
    fb = get_in(ctx, [:artifacts, :review_feedback])

    base =
      if developer_role?(role) and is_binary(fb) and String.trim(fb) != "" do
        base <>
          "\n\n## Reviewer feedback to address (re-work)\n\n" <>
          fb <> "\n\nApply these specific changes; do not introduce unrelated changes."
      else
        base
      end

    # On an orientation-doc re-work pass (turn-0 OR post-curator — both
    # phases of run_orientation_repair/1 write the SAME artifact key), thread
    # the violation list to the curator. Reads the SAME key
    # `run_orientation_repair/1` writes (`:curator_doc_violations`) — these
    # were historically two different keys (write `:curator_doc_violations`,
    # read `:factcheck_violations`), so the re-invoked curator was handed
    # the raw pitch with NO violation list at all, asked to fix violations
    # it was never shown. This is the ONE deterministic, non-`ev:learned`
    # input block context-curator's role contract permits — see
    # `shared/rules/roles/context-curator.md` § Constraints.
    fv = get_in(ctx, [:artifacts, :curator_doc_violations])

    base =
      if role == "context-curator" and is_binary(fv) and String.trim(fv) != "" do
        base <>
          "\n\n## Orientation-doc violations to fix\n\n" <>
          fv <> "\n\nEdit only the named orientation docs; do not introduce unrelated changes."
      else
        base
      end

    # On an unparseable-review re-work pass, ask the reviewer to re-state
    # its verdict with the required sentinel.
    rvm = get_in(ctx, [:artifacts, :review_verdict_missing])

    base =
      if (role == "reviewer-phoenix" or role == "reviewer-static") and is_binary(rvm) and
           String.trim(rvm) != "" do
        base <> "\n\n## Verdict required (re-work)\n\n" <> rvm
      else
        base
      end

    # On an incomplete-coverage re-work pass, ask the reviewer to re-state
    # its REVIEW_COVERAGE: lines to fully name the ## Files Modified set.
    rci = get_in(ctx, [:artifacts, :review_coverage_incomplete])

    base =
      if (role == "reviewer-phoenix" or role == "reviewer-static") and is_binary(rci) and
           String.trim(rci) != "" do
        base <> "\n\n## Coverage required (re-work)\n\n" <> rci
      else
        base
      end

    # On an env-var re-work pass, thread the undocumented-var list to the developer.
    ev = get_in(ctx, [:artifacts, :env_var_violation])

    base =
      if developer_role?(role) and is_binary(ev) and String.trim(ev) != "" do
        base <>
          "\n\n## Undeclared env var(s) to fix (re-work)\n\n" <>
          "The following env var(s) are read (System.get_env/fetch_env) in the working " <>
          "tree diff but are not declared in .env.sample and/or .env.prod.sample:\n\n" <>
          ev <> "\n\nDeclare each in BOTH sample files; do not introduce unrelated changes."
      else
        base
      end

    # Reviewers get the loop-derived changed-file set under the exact heading
    # their baked contract names (## Files Modified) — the file set was the
    # actual gap that made a reviewer refuse a gate-green cycle (pitch
    # "reviewer handoff names the files under review"). The change is
    # UNCOMMITTED in the working tree; content is one allowed
    # `git diff HEAD -- <path>` away (reviewer-bash-allowlist permits it).
    # Reviewers must also emit a machine-readable verdict the loop can act
    # on (#7).
    base =
      if role == "reviewer-phoenix" or role == "reviewer-static" do
        files = get_in(ctx, [:artifacts, :review_file_set]) || ""

        file_section =
          if String.trim(files) != "" do
            "\n\n## Files Modified\n\n" <>
              "The following files changed this cycle (UNCOMMITTED in the working tree). " <>
              "Read any file's content with `git diff HEAD -- <path>`:\n\n" <>
              "```\n" <> String.trim(files) <> "\n```"
          else
            ""
          end

        # Move 1 (pitch "hand each role the material its job needs"): the
        # diff itself, not just the file names — the gate that graded this
        # exact tree already shelled this diff seconds earlier
        # (`review_diff` from `invoke_reviewer/4`'s capture); handing it
        # here means the reviewer never has to re-derive it turn-by-turn via
        # `git diff` (measured: 139 of 165 reviewer Bash calls on one build
        # were exactly this re-derivation).
        diff_block = get_in(ctx, [:artifacts, :review_diff]) || ""

        diff_section =
          if String.trim(diff_block) != "" do
            "\n\n## Diff under review\n\n" <>
              "The diff below is the SAME uncommitted working-tree change named above — " <>
              "read it here; you do not need to re-derive it with `git diff`.\n\n" <> diff_block
          else
            ""
          end

        # Move 2: on a re-review pass, the delta since THIS reviewer's own
        # last pass, plus the finding that pass raised, plus the price of
        # this verdict. `review_diff_delta` is only ever stashed by
        # `invoke_reviewer/4` when a prior digest map existed (i.e. never
        # on pass 1) — no block for a first pass.
        since_last_section = since_last_review_section(ctx)

        verifier_notice = verifier_surface_notice(files)

        coverage_instruction =
          if String.trim(files) != "" do
            "\n\nBefore your terminal verdict line, emit one `REVIEW_COVERAGE:` line per " <>
              "path listed under ## Files Modified above — no more, no fewer: " <>
              "`REVIEW_COVERAGE: <path> read` for a path you actually read, or " <>
              "`REVIEW_COVERAGE: <path> skipped: <reason>` for one you intentionally did " <>
              "not (a non-blocking, legitimate answer — state why). An APPROVED verdict " <>
              "must state what surface it covers."
          else
            ""
          end

        base <>
          file_section <>
          diff_section <>
          since_last_section <>
          verifier_notice <>
          "\n\nReview these changes against normal reviewer checks (quality, security, " <>
          "silent-failure/Rule S, test coverage)." <>
          coverage_instruction <>
          "\n\nEND your response with exactly one terminal line: " <>
          "`REVIEW_VERDICT: APPROVED` when acceptable; otherwise put required changes before " <>
          "the terminal line `REVIEW_VERDICT: CHANGES_REQUESTED`."
      else
        base
      end

    # Structural gap #8: the committer must be told to COMMIT the working tree —
    # not handed the raw feature pitch (which makes it inspect the repo, see the
    # feature already implemented by the developer, and no-op with "done", the
    # observed Phoenix false-success). Give it an unambiguous commit directive;
    # the pitch is context only.
    base =
      if role == "committer" do
        "The developer and reviewer for this cycle have already implemented and approved " <>
          "the change; ALL of it is sitting UNCOMMITTED in the project's working tree. Your " <>
          "ONLY job is to stage EVERY change (tracked modifications AND new untracked files) " <>
          "and create EXACTLY ONE git commit with a concise, why-focused message. Do NOT " <>
          "implement, modify, or re-verify features. If `git status --porcelain` is empty " <>
          "(nothing to commit), STOP and report that as a failure — it means the cycle " <>
          "produced no changes.\n\n## Task that was implemented (context only)\n\n" <> base
      else
        base
      end

    if reason do
      base <>
        "\n\nPrevious attempt at role #{role} failed with: #{reason}. Please address this and retry."
    else
      base
    end
  end

  @claude_settings_path Path.expand(
                          "../../../harnesses/claude/claude-code-settings.json",
                          __DIR__
                        )

  @doc """
  Resolves the B-bucket in-agent guard bundle flag for `harness`:

  - `"claude_code"` → `["--settings=@<claude-code-settings.json>"]`

  The `"claude_code"` bundle is the FULL installed `claude-code-settings.json`
  (every registered hook), not a reduced bundle. Each loop-invoked
  codegen-call now runs `claude --agent <role>`, which stamps `.agent_type`
  natively — the same identity signal a real subagent spawn carries — so
  AGENT_TYPE-gated role guards (committer/reviewer/curator/developer) and the
  two orchestrator-* confinement guards (which bypass on either agent_id OR
  agent_type) apply exactly as they do under the legacy (non-loop) path. There
  is no longer a reduced hook subset — the loop and legacy paths share one
  settings.json.

  RAISES (crash loud) if the resolved bundle path is absent — every role
  invocation MUST carry its guard bundle; a silently-unguarded run (e.g.
  committer without committer-single-commit-per-cycle, developer without
  llm-suite-guard) is exactly the failure mode this guards against.

  `opts`:
  - `:claude_settings_path` — override for testing (default: the committed
    `harnesses/claude/claude-code-settings.json` full settings)
  """
  @spec guard_bundle_flag!(harness(), run_opts()) :: [String.t()]
  def guard_bundle_flag!(harness, opts \\ [])

  def guard_bundle_flag!("claude_code", opts) do
    path = Keyword.get(opts, :claude_settings_path, @claude_settings_path)

    unless File.exists?(path) do
      raise "OrchestrationLoop: claude settings bundle not found at #{path} — refusing to run a role unguarded"
    end

    ["--settings=@#{path}"]
  end

  def guard_bundle_flag!(other, _opts) do
    raise "OrchestrationLoop: unknown harness #{inspect(other)} — cannot resolve guard bundle"
  end

  @doc """
  Returns the trailing `codegen-call` argv tail for a prompt: an explicit
  `--` end-of-flags separator immediately followed by the prompt. Prompt
  content (pitch body) is DATA, never CLI flags — a body that happens to
  open with `-` or `--` (e.g. stray YAML-like text) must never be parsed
  as an option by `codegen-call`'s `OptionParser`. Used by the role-call
  `codegen-call` invocation site.
  """
  @spec prompt_tail(String.t()) :: [String.t()]
  def prompt_tail(prompt), do: ["--", prompt]

  defp default_codegen_call(
         cwd,
         harness,
         model,
         effort,
         system_prompt_path,
         allowed_tools,
         prompt,
         transcript,
         agent,
         resume_session_id,
         cold_session_id,
         base_head
       ) do
    unless File.exists?(@codegen_call_bin) do
      raise "OrchestrationLoop: codegen-call not found at #{@codegen_call_bin}"
    end

    # --resume (warm-resume a transient-retry attempt) and --session-id
    # (pin a NEW cold call's id up front) are mutually exclusive per
    # attempt — resume wins when both are somehow present.
    args =
      [
        "--harness=#{harness}",
        "--model=#{model}",
        "--effort=#{effort}"
      ] ++
        if(system_prompt_path && system_prompt_path != "",
          do: ["--system-prompt=@#{system_prompt_path}"],
          else: []
        ) ++
        if(agent && agent != "", do: ["--agent=#{agent}"], else: []) ++
        cond do
          resume_session_id && resume_session_id != "" ->
            ["--resume=#{resume_session_id}"]

          cold_session_id && cold_session_id != "" ->
            ["--session-id=#{cold_session_id}"]

          true ->
            []
        end ++
        guard_bundle_flag!(harness) ++
        if(allowed_tools && allowed_tools != "",
          do: ["--allowed-tools=#{allowed_tools}"],
          else: []
        ) ++ prompt_tail(prompt)

    # CODEGEN_RESUME_ATTEMPT: set only on a warm-resume transient retry,
    # to the session id being resumed into — a stable token the
    # developer-no-self-gate guard uses to distinguish "first gate check
    # after resuming" from a genuine same-tree spin (see hook comment).
    env =
      [
        {"CODEGEN_DIR", @codegen_dir},
        {"CODEGEN_BUILD_START_TS", Integer.to_string(System.system_time(:second))},
        {"CODEGEN_CYCLE_BASE_SHA", base_head || ""},
        {"CODEGEN_LOOP", "1"}
      ] ++
        if(transcript, do: [{"CODEGEN_CALL_TRANSCRIPT_PATH", transcript}], else: []) ++
        if(resume_session_id && resume_session_id != "",
          do: [{"CODEGEN_RESUME_ATTEMPT", resume_session_id}],
          else: []
        ) ++
        waived_guards_env(agent) ++
        log_path_env()

    {stdout, stderr, exit_code} = run_call_split(@codegen_call_bin, args, env, cwd)

    decode_envelope!(stdout, stderr, exit_code)
  end

  # Runs `bin` with `args` under `cd`/`env`, with stdout and stderr captured
  # SEPARATELY rather than merged — a role call's JSON envelope lives on
  # stdout alone; any diagnostic line the child writes to stderr (retry
  # notices, watchdog grace-kill messages, etc.) must never be able to land
  # in front of the envelope and corrupt the JSON parse. Implemented via a
  # `sh -c 'exec "$@" 2>"$CG_ERR"'` wrapper: `exec` replaces the shell with
  # `bin` in place, so no extra process layer is introduced and pgid/kill
  # semantics are unchanged; stderr is redirected to a temp file, read back,
  # and returned so the caller can still re-emit it (the drain's `_build.log`
  # is a stdout+stderr capture — dropping stderr here would silently lose
  # diagnostics that operators rely on).
  @spec run_call_split(String.t(), [String.t()], list(), String.t()) ::
          {String.t(), String.t(), non_neg_integer()}
  defp run_call_split(bin, args, env, cwd) do
    err_path =
      Path.join(
        System.tmp_dir!(),
        "codegen-call-stderr-#{System.unique_integer([:positive])}.log"
      )

    try do
      {stdout, exit_code} =
        System.cmd(
          "sh",
          ["-c", ~s(exec "$@" 2>"$CG_ERR"), "sh", bin | args],
          env: [
            {"CG_ERR", err_path},
            {"CODEGEN_CALL_OWNER_OS_PID", System.pid()}
            | env
          ],
          cd: cwd,
          stderr_to_stdout: false
        )

      stderr =
        case File.read(err_path) do
          {:ok, content} -> content
          {:error, _reason} -> ""
        end

      # Re-emit captured stderr to this process's own stderr so it still
      # reaches the drain's `_build.log` (a stdout+stderr Port capture) —
      # content is preserved even though it now appears at call completion
      # rather than streaming live.
      if stderr != "", do: IO.write(:stderr, stderr)

      {stdout, stderr, exit_code}
    after
      File.rm(err_path)
    end
  end

  # Decodes a role call's stdout into its result envelope. A non-zero exit
  # is an OPERATIONAL failure (transient claude SIGTERM/exit 143, rate-limit
  # kill, network blip) — NOT a programming error. Return a synthetic failed
  # envelope so invoke_with_retry/4 retries the role ONCE instead of crashing
  # the whole multi-role cycle. A genuinely broken role still fails cleanly
  # (failed status after the retry), never a raw crash that discards all
  # prior role work.
  #
  # Malformed JSON on a zero exit IS an unexpected contract violation — crash
  # loud, but name the cause: quote what was actually received (stdout head
  # + stderr tail) instead of a bare byte-offset decode error.
  @spec decode_envelope!(String.t(), String.t(), integer()) :: map()
  defp decode_envelope!(stdout, stderr, exit_code) do
    if exit_code != 0 do
      combined = stdout <> stderr

      %{
        "result" => %{
          "status" => "failed",
          "reason" =>
            "codegen-call exited #{exit_code} (transient?): #{String.slice(combined, max(String.length(combined) - 400, 0), 400)}"
        }
      }
    else
      case Jason.decode(stdout) do
        {:ok, decoded} ->
          decoded

        {:error, decode_error} ->
          received = String.slice(stdout, 0, 200)
          stderr_tail = String.slice(stderr, max(String.length(stderr) - 200, 0), 200)

          raise "OrchestrationLoop: expected JSON envelope on codegen-call stdout, " <>
                  "got: #{inspect(received)} (decode error: #{Exception.message(decode_error)}); " <>
                  "stderr tail: #{inspect(stderr_tail)}"
      end
    end
  end

  @doc """
  Advances `codegen/gate-pending/cycle-state.json` for `project_dir` to
  `state` (one of `CYCLE_STATE_ORDER`: GATED, REVIEWED, CURATED,
  COMMITTED) via `cycle-state.sh`'s `write_cycle_state`. `verdict` is
  meaningful only for `"GATED"` — pass `""` for other states. `slug` is the
  pitch slug that owns this cycle — stamped into the checkpoint so a LATER
  cycle can verify (before resuming) that the checkpoint is its own and not
  a foreign pitch's corpse. Pass `""` when no slug is known (mirrors the
  existing tolerance for empty `step_log`/`session_id`).
  """
  @spec advance_cycle_state(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          :ok
  def advance_cycle_state(state, step_log, session_id, verdict, project_dir, slug \\ "") do
    unless File.exists?(@cycle_state_lib) do
      raise "OrchestrationLoop: cycle-state.sh not found at #{@cycle_state_lib}"
    end

    script =
      "source #{shell_quote(@cycle_state_lib)} && write_cycle_state " <>
        Enum.map_join(
          [state, step_log, session_id, verdict, project_dir, slug],
          " ",
          &shell_quote/1
        )

    {_output, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    :ok
  end

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  # ── Telemetry accumulation (benchmark instrumentation) ──────────────────────
  # The loop invokes N per-role codegen-calls, each returning an envelope whose
  # top-level `usage` block carries cost/tokens/num_turns (call-dispatch.sh).
  # We sum these across EVERY invocation (including gate retries — they cost
  # real tokens) into the loop process dictionary so the mix task can emit a
  # single aggregated `type:result` line for the benchmark harness to parse.

  @telemetry_key :loop_telemetry

  @doc false
  def zero_telemetry do
    %{
      cost_usd: 0.0,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      num_turns: 0,
      role_calls: 0,
      per_role: %{}
    }
  end

  @doc false
  def get_telemetry, do: Process.get(@telemetry_key, zero_telemetry())

  @doc false
  @spec accumulate_telemetry(String.t(), map()) :: :ok
  def accumulate_telemetry(role, envelope), do: accumulate_telemetry(role, envelope, %{})

  # `dispatch` carries the {harness, model, effort, source, native_effort}
  # this specific invocation actually requested — populated by
  # `invoke_role/4` from the SAME resolved values used to build the
  # `codegen_call_fn.(...)` call, so it can never drift from what was truly
  # dispatched. `source` names WHICH precedence rung supplied the effort
  # (`:role_config` | `:build_override` | `:escalation` | `:campaign`);
  # `native_effort` names the adapter-realized control (e.g.
  # "settings.MAX_THINKING_TOKENS=0" for a claude `off`, "--effort high"
  # otherwise) — see
  # `native_effort_realization/2`. Empty map (the /2 delegate above, and any
  # other pre-existing caller) means "unknown", never a fabricated tuple —
  # `emit_loop_telemetry/1` reads it as an optional field per role_entry.
  @doc false
  @spec accumulate_telemetry(String.t(), map(), map()) :: :ok
  def accumulate_telemetry(role, %{"usage" => usage} = envelope, dispatch)
      when is_map(usage) and is_map(dispatch) do
    acc = get_telemetry()

    role_entry = %{
      cost_usd: t_num(usage["cost_usd"]),
      input_tokens: t_int(usage["input_tokens"]),
      output_tokens: t_int(usage["output_tokens"]),
      cache_read_tokens: t_int(usage["cache_read_input_tokens"]),
      cache_creation_tokens: t_int(usage["cache_creation_input_tokens"]),
      num_turns: t_int(usage["num_turns"]),
      # Previously-emitted, previously-unread signals — see pitch
      # "build-cycle-accounts-for-its-own-time". Unknown stays unknown:
      # t_opt_int/1 carries `nil` through rather than coercing an
      # absent/malformed value to a fabricated 0 (unlike t_int/t_num above,
      # which back existing arithmetic sums and must stay byte-identical).
      latency_ms: t_opt_int(usage["latency_ms"]),
      duration_ms: t_opt_int(usage["duration_ms"]),
      duration_api_ms: t_opt_int(usage["duration_api_ms"]),
      ttft_ms: t_opt_int(usage["ttft_ms"]),
      permission_denials: t_opt_int(usage["permission_denials"]),
      stop_reason: usage["stop_reason"],
      # `metrics` is OMITTED (not zeroed) by the envelope on any abnormal
      # call — see call-dispatch.sh's METRICS="null" guard. Reading it as
      # nil-when-absent here preserves that "unknown, not zero" contract;
      # never default to %{}.
      metrics: Map.get(envelope, "metrics"),
      dispatch: %{
        harness: Map.get(dispatch, :harness),
        model: Map.get(dispatch, :model),
        effort: Map.get(dispatch, :effort),
        source: Map.get(dispatch, :source),
        native_effort: Map.get(dispatch, :native_effort)
      }
    }

    updated = %{
      cost_usd: acc.cost_usd + role_entry.cost_usd,
      input_tokens: acc.input_tokens + role_entry.input_tokens,
      output_tokens: acc.output_tokens + role_entry.output_tokens,
      cache_read_tokens: acc.cache_read_tokens + role_entry.cache_read_tokens,
      cache_creation_tokens: acc.cache_creation_tokens + role_entry.cache_creation_tokens,
      num_turns: acc.num_turns + role_entry.num_turns,
      role_calls: acc.role_calls + 1,
      per_role: Map.update(acc.per_role, role, [role_entry], &(&1 ++ [role_entry]))
    }

    Process.put(@telemetry_key, updated)
    :ok
  end

  def accumulate_telemetry(_role, _envelope, _dispatch), do: :ok

  # Appends one JSONL line to <cwd>/codegen/logging/<cycle_id>/cycle-summary.jsonl
  # per role invocation — a durable per-cycle turn-summary alongside the raw
  # per-role transcript files. A nil cycle_id (legacy/one-shot callers, or
  # cycle_id-free ExUnit calls) is a no-op: no directory, no file.
  # Why this invocation is happening, read off the artifacts the loop already
  # threads into the prompt for exactly this purpose. Naming the cause is what
  # turns "the developer ran 3 times" into an actionable number: three gate
  # failures and three reviewer bounces are the same count and completely
  # different problems.
  #
  # Order matters — a transport retry is checked first because it is a
  # continuation of the SAME logical call (the fault artifacts from the
  # original attempt are still on ctx and would otherwise mislabel it).
  @spec call_reason(map(), String.t(), pos_integer()) :: String.t()
  defp call_reason(ctx, role, role_call) do
    artifacts = ctx[:artifacts] || %{}
    present? = fn key -> is_binary(artifacts[key]) and String.trim(artifacts[key]) != "" end

    cond do
      (artifacts[:transport_attempt] || 1) > 1 -> "transport_retry"
      role_call == 1 -> "initial"
      present?.(:review_feedback) -> "review_changes_requested"
      present?.(:curator_doc_violations) -> "orientation_repair"
      present?.(:last_failure_reason) -> "gate_failed"
      developer_role?(role) -> "gate_failed"
      true -> "rework"
    end
  end

  defp write_cycle_summary(nil, _cwd, _role, _seq, _transcript, _envelope, _attempt), do: :ok

  defp write_cycle_summary(cycle_id, cwd, role, seq, transcript, envelope, attempt) do
    usage = Map.get(envelope, "usage", %{})

    line =
      Jason.encode!(%{
        "role" => role,
        "seq" => seq,
        # Rework accounting, stated rather than inferred. `call` is the Nth
        # invocation of this role this cycle; `call_reason` says what caused
        # it; `transport_attempt` distinguishes a retried round-trip from a
        # first one. A build that reworks twice now says so in its own log.
        "call" => Map.get(attempt, "call", 1),
        "call_reason" => Map.get(attempt, "call_reason", "initial"),
        "transport_attempt" => Map.get(attempt, "transport_attempt", 1),
        "transport_attempt_max" => Map.get(attempt, "transport_attempt_max"),
        "num_turns" => t_int(usage["num_turns"]),
        "cost_usd" => t_num(usage["cost_usd"]),
        "status" => get_in(envelope, ["result", "status"]),
        "transcript" => transcript,
        # Widened per pitch "build-cycle-accounts-for-its-own-time" Move 1/3
        # — signals both harnesses already emit, previously dropped on
        # arrival. Absent -> null, never a fabricated 0 (masking-default
        # discipline); a null here means "unknown", not "zero".
        "latency_ms" => t_opt_int(usage["latency_ms"]),
        "duration_ms" => t_opt_int(usage["duration_ms"]),
        "duration_api_ms" => t_opt_int(usage["duration_api_ms"]),
        "ttft_ms" => t_opt_int(usage["ttft_ms"]),
        "permission_denials" => t_opt_int(usage["permission_denials"]),
        "stop_reason" => usage["stop_reason"],
        "metrics" => Map.get(envelope, "metrics")
      })

    dir = Path.join([cwd, "codegen", "logging", cycle_id])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cycle-summary.jsonl"), line <> "\n", [:append])
    :ok
  end

  defp t_num(nil), do: 0.0
  defp t_num(n) when is_number(n), do: n

  defp t_num(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp t_num(_), do: 0.0

  defp t_int(nil), do: 0
  defp t_int(n) when is_integer(n), do: n
  defp t_int(n) when is_float(n), do: trunc(n)

  defp t_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp t_int(_), do: 0

  # Null-preserving siblings of t_int/1 and t_num/1 — used ONLY for the new
  # observability fields (latency_ms, duration_ms, duration_api_ms, ttft_ms,
  # permission_denials). Unlike t_int/1 (which backs existing arithmetic
  # sums and must keep coercing absent -> 0 to avoid crashing them), these
  # carry an absent/malformed value through as `nil` — a fabricated 0 would
  # read as "instant"/"free"/"no denials" and mask exactly the gap this
  # pitch exists to surface. t_int/1 and t_num/1 are left byte-identical.
  @spec t_opt_int(term()) :: integer() | nil
  defp t_opt_int(nil), do: nil
  defp t_opt_int(n) when is_integer(n), do: n
  defp t_opt_int(n) when is_float(n), do: trunc(n)

  defp t_opt_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp t_opt_int(_), do: nil

  # ── Fixed campaign binding (RoleModelSweep) ─────────────────────────────
  # A `RoleModelSweep` campaign arm pins ONE role's harness/model/effort for
  # the whole build by writing `role-model-binding.json` into
  # `BENCH_RUN_DIR` before spawning this loop as a child process. Read once
  # per process (cached in the process dictionary — a mid-run edit is NOT
  # honored, matching the campaign's own "pin at spawn" contract) and
  # validated eagerly: a PRESENT-but-invalid file raises before the first
  # role runs (fail loud, never a silently-ignored malformed directive).
  # Absent file (BENCH_RUN_DIR unset, or the file doesn't exist there) ->
  # `:none` for every role — ordinary benchmark/build behavior, byte-for-byte
  # unchanged from before this feature existed.
  @fixed_binding_key :role_model_sweep_binding

  defp resolve_fixed_binding(role, harness, opts) do
    case load_fixed_binding(opts) do
      %{"role" => ^role, "harness" => bound_harness, "model" => model, "effort" => effort} ->
        if normalize_harness_for_binding(bound_harness) == normalize_harness_for_binding(harness) do
          {model, effort}
        else
          :none
        end

      _ ->
        :none
    end
  end

  defp normalize_harness_for_binding("claude"), do: "claude_code"
  defp normalize_harness_for_binding(other), do: other

  defp load_fixed_binding(opts) do
    case Process.get(@fixed_binding_key, :unset) do
      :unset ->
        binding = read_and_validate_fixed_binding(opts)
        Process.put(@fixed_binding_key, binding)
        binding

      cached ->
        cached
    end
  end

  defp read_and_validate_fixed_binding(opts) do
    run_dir = System.get_env("BENCH_RUN_DIR")

    if is_nil(run_dir) or String.trim(run_dir) == "" do
      nil
    else
      path = Path.join(run_dir, "role-model-binding.json")

      if File.exists?(path) do
        path
        |> File.read!()
        |> Jason.decode!()
        |> validate_fixed_binding!(path, opts)
      else
        nil
      end
    end
  end

  @fixed_binding_required_keys ~w(schema_version campaign_id arm role stack harness model effort source_sha fixed)

  defp validate_fixed_binding!(binding, path, opts)

  defp validate_fixed_binding!(%{} = binding, path, opts) do
    missing = Enum.reject(@fixed_binding_required_keys, &Map.has_key?(binding, &1))

    unless missing == [] do
      raise "OrchestrationLoop: #{path} missing required key(s): #{inspect(missing)}"
    end

    unless binding["fixed"] == true do
      raise "OrchestrationLoop: #{path} \"fixed\" must be true, got: #{inspect(binding["fixed"])}"
    end

    unless is_binary(binding["role"]) and binding["role"] != "" do
      raise "OrchestrationLoop: #{path} \"role\" must be a non-empty string"
    end

    unless is_binary(binding["harness"]) and binding["harness"] in ["claude", "claude_code"] do
      raise "OrchestrationLoop: #{path} \"harness\" must be one of claude/claude_code, got: #{inspect(binding["harness"])}"
    end

    unless is_binary(binding["model"]) and binding["model"] != "" do
      raise "OrchestrationLoop: #{path} \"model\" must be a non-empty string"
    end

    unless is_binary(binding["effort"]) and binding["effort"] in ["low", "medium", "high"] do
      raise "OrchestrationLoop: #{path} \"effort\" must be one of low/medium/high, got: #{inspect(binding["effort"])}"
    end

    unless is_binary(binding["source_sha"]) and binding["source_sha"] != "" do
      raise "OrchestrationLoop: #{path} \"source_sha\" must be a non-empty string"
    end

    validate_fixed_binding_source_sha!(binding, path, opts)

    binding
  end

  defp validate_fixed_binding!(other, path, _opts) do
    raise "OrchestrationLoop: #{path} must decode to a JSON object, got: #{inspect(other)}"
  end

  # Guards against a campaign arm silently measuring a DIFFERENT codegen
  # source revision than the one it was pinned against — the pitch's own
  # requirement is that a dirty codegen worktree or a moved HEAD stops the
  # campaign as INCONCLUSIVE, never lets the loop proceed against a fixed
  # binding whose provenance no longer matches. `RoleModelSweep.preflight!/1`
  # only checks this ONCE, in the long-lived runner process, at campaign
  # start; this repeats the check on every child-process read of the binding
  # file so a mid-campaign edit/rebase to the codegen root (or a dirty tree
  # produced between repetitions) is caught here too, not just at t=0.
  #
  # `git_head_fn`/`git_dirty_fn` are test seams (opts, defaulting to real
  # `git` calls against `@codegen_dir`) so this stays hermetically testable
  # without a live git dependency.
  defp validate_fixed_binding_source_sha!(binding, path, opts) do
    git_head_fn = Keyword.get(opts, :git_head_fn, &default_git_head/0)
    git_dirty_fn = Keyword.get(opts, :git_dirty_fn, &default_git_dirty?/0)

    current_sha = git_head_fn.()

    unless binding["source_sha"] == current_sha do
      raise "OrchestrationLoop: #{path} \"source_sha\" (#{inspect(binding["source_sha"])}) " <>
              "does not match current codegen HEAD (#{inspect(current_sha)}) — " <>
              "campaign arm — fallback suppressed; source drift makes this arm INCONCLUSIVE"
    end

    if git_dirty_fn.() do
      raise "OrchestrationLoop: #{path} codegen root worktree is dirty at binding-read time — " <>
              "campaign arm — fallback suppressed; dirty tree makes this arm INCONCLUSIVE"
    end

    :ok
  end

  defp default_git_head do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: @codegen_dir, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, status} -> raise "OrchestrationLoop: git rev-parse HEAD failed (#{status}): #{out}"
    end
  end

  defp default_git_dirty? do
    case System.cmd("git", ["status", "--porcelain"], cd: @codegen_dir, stderr_to_stdout: true) do
      {out, 0} ->
        String.trim(out) != ""

      {out, status} ->
        raise "OrchestrationLoop: git status --porcelain failed (#{status}): #{out}"
    end
  end
end
