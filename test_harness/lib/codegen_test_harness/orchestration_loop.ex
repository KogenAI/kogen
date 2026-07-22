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

  alias CodegenTestHarness.{BuildLock, LoopGate, LoopQueue, RoleResolver}

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

  # Phoenix: plan-first. static: developer-first. Terminal role is committer
  # in both sequences — the gate/reviewer/curator/committer tail is common.
  @phoenix_roles ~w(planner-phoenix developer-phoenix-backend reviewer-phoenix context-curator committer)
  # Static is developer-first (no planner) by design — static tasks are simpler and
  # the planner is an opus-priced role whose scoping isn't needed for them. (An
  # experiment briefly added planner-static to suppress "gold-plating" like SEO/OG
  # metadata, but that polish is not a defect, so the planner was reverted here.)
  # build_prompt/2 still threads a planner's plan to the developer WHEN one runs —
  # i.e. on the phoenix (plan-first) sequence.
  @static_roles ~w(developer-static reviewer-static context-curator committer)

  @cycle_state_lib Path.expand(
                     "../../../harnesses/claude/hooks/lib/cycle-state.sh",
                     __DIR__
                   )

  @transcript_seq_key :loop_transcript_seq
  @cycle_id_key :loop_cycle_id
  @log_path_key :loop_log_path

  @codegen_call_bin Path.expand("../../../codegen-call", __DIR__)
  @codegen_log_bin Path.expand("../../../codegen-log", __DIR__)
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
  - `:harness` — `"claude_code"` | `"pi"` (required)
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
    which a bypassing role could forge) and raises when `role != "committer"`
    — see § Enforcement in `shared/rules/_core/session-log.md`.
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
    events (planner/developer/reviewer), the curator either routed at least
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
    Diverges from `:max_review_cycles` (which proceeds on budget
    exhaustion): exhaustion fails the cycle LOUD instead of proceeding — the
    committer cannot Read/Edit `context/*.md`, so handing it a known-bad doc
    is an unfixable dead-end that used to deadlock as a compounding
    dirty-tree retry.
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
    Exhaustion fails the cycle LOUD (same posture as
    `:max_curator_doc_cycles`, not `:max_review_cycles`'s
    proceed-on-exhaustion): an undeclared required env var is a real defect
    the app crashes on at runtime, so handing it onward unfixed is not safe.
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
    case resume_checkpoint(cwd, all_roles, opts) do
      {:resume, resume_role, state} ->
        roles = resume_suffix(all_roles, resume_role)
        ctx = %{cwd: cwd, pitch: pitch, artifacts: %{}, base_head: cycle_base_head(cwd)}
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
        clean_tree_fn = Keyword.get(opts, :clean_tree_preflight_fn, &preflight_clean_tree!/1)
        clean_tree_fn.(cwd)

        # A stale terminal-state.json from a PRIOR cycle must never leak
        # into this one — a fresh cycle start has produced no deterministic
        # exhaustion yet, so any marker on disk is left over from an
        # earlier, already-concluded cycle. Never unlinked on the `:resume`
        # branch above: exhaustion is terminal, not resumable, so a resumed
        # cycle never legitimately carries one either — but leaving it
        # alone there costs nothing (a resumed cycle only reaches a marker
        # write path via its own fresh exhaustion, same as any other).
        File.rm(Path.join([cwd, "codegen", "gate-pending", "terminal-state.json"]))

        ctx = %{cwd: cwd, pitch: pitch, artifacts: %{}, base_head: cycle_base_head(cwd)}
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

    # Corpus sync — carry any *_cycle.jsonl present on refs/heads/corpus but
    # absent locally into codegen/logging/ BEFORE this cycle's own log is
    # minted (see default_log_init below). Codegen-only (no-ops silently in
    # every downstream project — corpus_enabled's own registry.yaml
    # sentinel), fail-loud-non-blocking (stderr only, never raises, never
    # changes the cycle's outcome). See codegen-log's own `corpus sync`
    # header comment for the mechanism.
    corpus_sync_fn = Keyword.get(opts, :corpus_sync_fn, &default_corpus_sync/1)

    try do
      corpus_sync_fn.(cwd)
    rescue
      e ->
        IO.puts(:stderr, "OrchestrationLoop: corpus_sync_fn raised: #{Exception.message(e)}")
    end

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
    gate_command = preflight_gate!(cwd, opts)
    ctx = put_in(ctx, [:artifacts, :gate_command], gate_command)
    preflight_roles!(roles, cwd, opts)
    ctx = run_orientation_preflight(cwd, ctx, harness, opts)

    # Corpus publish — carry THIS cycle's own log onto refs/heads/corpus at
    # the tail, on the ok path, the error path, AND a raise (the `after`
    # block runs regardless), so a cycle that failed still contributes its
    # learnings to the shared corpus. `ev:exit` (dispatch.sh's own record of
    # the CHILD PROCESS's wait status) is written by the parent process
    # AFTER this loop has already exited — it is a dispatch-level fact, not
    # a learning, and is therefore never captured in the published copy by
    # design. Fail-loud-non-blocking: publish never raises past this point
    # and never changes the tail expression's own value.
    try do
      run_roles(roles, harness, ctx, opts)
    after
      corpus_publish_fn = Keyword.get(opts, :corpus_publish_fn, &default_corpus_publish/1)

      try do
        corpus_publish_fn.(cwd)
      rescue
        e ->
          IO.puts(
            :stderr,
            "OrchestrationLoop: corpus_publish_fn raised: #{Exception.message(e)}"
          )
      end
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
  defp preflight_roles!(roles, cwd, opts) do
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

      :error ->
        raise "OrchestrationLoop: could not confirm role-agent resolution (preflight probe " <>
                "returned no agent list): #{String.slice(output, 0, 400)}"
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
  # planner+developer+gate+reviewer+curator have all been paid for. Runs
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
  # LoopGate.decide_gate/1). Reuses the same resolution path the later gate run
  # takes (no :step_log in the real loop), so it cannot pass-then-fail. Rescues
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
  defp run_roles([], _harness, _ctx, _opts), do: :ok

  defp run_roles([role | rest], harness, ctx, opts) when role == "committer" do
    # No-ship-on-a-gate-that-didn't-grade-this-tree: the pre-commit re-gate
    # check has to run BEFORE the committer role is invoked at all — unlike
    # every other role clause below, this one intercepts ahead of the
    # `invoke_with_retry` call rather than after it.
    ensure_gate_graded_this_tree!(ctx, rest, harness, opts, 0)
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
    # No-op-curator-spawn-when-nothing-was-learned: read the cycle's own
    # log for the mechanical learning signal BEFORE invoking the curator at
    # all — unlike the generic clause below, this one can skip the
    # `invoke_with_retry` call entirely. `:learned` or `:absent` (fail-SAFE
    # default — a missing/unreadable signal is never read as "skip") spawn
    # the curator exactly as before. `:no_learning` (every role that ran
    # this cycle honestly declared, on the record, that it learned nothing
    # durable) skips the LLM spawn, but the doc-integrity scans and the
    # CURATED state advance still run unconditionally — those are the only
    # reason this step can't be deleted outright (see run_curator_doc_check/6),
    # and a pre-existing doc violation still routes back into a real
    # curator spawn via run_curator_doc_check's :violations branch.
    signal_fn =
      Keyword.get(opts, :curator_learning_signal_fn, &LoopGate.curator_learning_signal/1)

    log_file = Process.get(@log_path_key)

    case signal_fn.(log_file) do
      :no_learning ->
        run_format_step(ctx.cwd, opts)
        run_curator_doc_check(role, rest, harness, ctx, opts, 0)

      signal when signal in [:learned, :absent] ->
        with {:ok, result} <- invoke_with_retry(role, harness, ctx, opts) do
          ctx = put_in(ctx, [:artifacts, role], result)
          run_format_step(ctx.cwd, opts)
          run_curator_doc_check(role, rest, harness, ctx, opts, 0)
        end
    end
  end

  defp run_roles([role | rest], harness, ctx, opts) do
    with {:ok, result} <- invoke_with_retry(role, harness, ctx, opts) do
      ctx = put_in(ctx, [:artifacts, role], result)

      # No-developer-invoked-without-its-plan: immediately after a planner
      # role finishes, lift its ACTUAL plan — the typed {"ev":"plan",...}
      # event it wrote to the cycle log via `codegen-log append <role>
      # --plan @-` (hook-guaranteed present by stop-verify-planner-gate.sh)
      # — rather than trusting the envelope `result`'s `value` (that's the
      # planner's final CHAT MESSAGE, which can be a recap with no plan in
      # it at all) or re-parsing the free-form `ev:role` body prose (which
      # is contractually opaque — see session-log.md § the body is opaque,
      # never re-parsed as structure). An absent or blank plan event raises
      # here — one role in, before a developer is ever invoked on nothing.
      ctx =
        if planner_role?(role) do
          plan = resolve_planner_plan!(role, opts)
          put_in(ctx, [:artifacts, :planner_plan], plan)
        else
          ctx
        end

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

  defp planner_role?(role), do: String.starts_with?(role, "planner-")

  defp reviewer_role?(role), do: String.starts_with?(role, "reviewer-")

  # Resolves the planner's plan text for threading into build_prompt/2, via
  # the :planner_plan_fn seam (default reads the real cycle log's typed
  # {"ev":"plan",...} event through LoopGate.planner_plan/1). Fail-closed: an
  # absent or blank plan event raises immediately rather than letting a
  # developer run with no plan — the plan is a typed marker, never
  # re-parsed out of the planner's free-form role body prose (see
  # session-log.md § the body is opaque, never re-parsed as structure).
  defp resolve_planner_plan!(role, opts) do
    plan_fn = Keyword.get(opts, :planner_plan_fn, &default_planner_plan/1)
    log_file = Process.get(@log_path_key)
    plan = plan_fn.(log_file)

    if is_binary(plan) and String.trim(plan) != "" do
      plan
    else
      raise "OrchestrationLoop: #{role} wrote no {\"ev\":\"plan\"} event to cycle log " <>
              "#{inspect(log_file)} — refusing to invoke a developer with no plan"
    end
  end

  defp default_planner_plan(log_file), do: LoopGate.planner_plan(log_file)

  # No-ship-on-a-gate-that-didn't-grade-this-tree: runs immediately BEFORE
  # the committer role is invoked (keyed on the role about to run, not its
  # predecessor, so it holds for both the phoenix and static sequences — the
  # context-curator, `run_format_step`, and env-var steps are all sequenced
  # ahead of the committer in both). A tree that changed since the last gate
  # ran (curator doc edits, formatting, or a destructive revert like the
  # incident that motivated this guard) means the recorded verdict no longer
  # describes what's about to be committed — re-gate to restamp a verdict
  # for the CURRENT tree before the committer ever runs.
  #
  # Match (or no comparable signature — non-git cwd, or no prior gate has
  # run in this cycle's opts, e.g. most mocked unit tests) → proceed
  # straight to the committer. Stale → re-gate via the same `LoopGate.run_gate/2`
  # contract the primary gate loop uses. Clear on re-gate → proceed. Non-clear
  # → route through the SAME developer-rework shape `do_gate_loop/9` uses
  # (fold the gate failure reason + rework brief into context, re-invoke the
  # developer, re-format, re-check), bounded by `:max_final_gate_cycles`
  # (default 1 — separate from `:max_gate_retries`; this is a pre-commit
  # backstop, not the primary gate loop). Exhaustion → `{:error, reason}`,
  # no commit.
  defp ensure_gate_graded_this_tree!(ctx, rest, harness, opts, cycle) do
    case gate_tree_match?(ctx.cwd, opts) do
      true ->
        run_committer(ctx, rest, harness, opts)

      false ->
        max_cycles = Keyword.get(opts, :max_final_gate_cycles, 1)

        if cycle < max_cycles do
          rework_final_gate(ctx, rest, harness, opts, cycle)
        else
          {:error,
           "pre-commit re-gate: tree changed since the gate ran and the gate stayed non-clear " <>
             "after #{cycle + 1} rework attempt(s) — refusing to invoke the committer on a tree " <>
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

  defp run_committer(ctx, rest, harness, opts) do
    with {:ok, result} <- invoke_with_retry("committer", harness, ctx, opts) do
      ctx = put_in(ctx, [:artifacts, "committer"], result)

      # Structural gap #9: the committer ROLE returning success does NOT
      # prove a commit landed — the committer can inspect the repo, see the
      # feature already implemented (it was, by the developer), and report
      # "done" without ever running `git commit`. Trusting role-return here
      # is the exact false-success failure the loop exists to prevent. VERIFY
      # the working tree is actually clean (all cycle output committed); a
      # dirty tree after the committer means it did not commit → fail loud.
      verify_committed!(ctx.cwd, ctx.base_head)
      advance_cycle_state_step("COMMITTED", ctx, opts)
      run_roles(rest, harness, ctx, opts)
    end
  end

  # Re-gates the CURRENT tree (the same `:gate_fn` contract `do_gate_loop/9`
  # uses) before the committer runs. Clear → proceed to the committer
  # (restamped `gate-result.json` now matches). Non-clear → resolve the
  # OWNER of the failure via `resolve_gate_owner/2` (the same owner-routing
  # `do_gate_loop/9`'s owner arm already uses — a `context/*.md` /
  # `PROJECT_CONTEXT.md` witness routes to `context-curator`, everything
  # else keeps routing to the cycle's developer), fold the gate failure
  # into context (mirrors `do_gate_loop/9`'s rework shape), then recurse
  # into `ensure_gate_graded_this_tree!/5` for another match check + gate
  # cycle. No developer role in this cycle's artifacts (should not happen
  # in practice — a developer always runs before the committer in both
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
        run_committer(ctx, rest, harness, opts)

      {:failed, _gate_cmd} ->
        dev_role = dev_role_from_ctx(ctx)

        if is_nil(dev_role) do
          {:error,
           "pre-commit re-gate failed and no developer role is present in this cycle's " <>
             "artifacts to route rework to (loop_failed, never a false loop_committed)."}
        else
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

          with {:ok, result} <- invoke_with_retry(rework_role, harness, retry_ctx, opts) do
            ctx =
              retry_ctx
              |> put_in([:artifacts, rework_role], result)
              |> update_in([:artifacts], &Map.delete(&1, :escalated_model))

            run_format_step(ctx.cwd, opts)
            ensure_gate_graded_this_tree!(ctx, rest, harness, opts, cycle + 1)
          end
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

  # Maps a completed cycle-state to the role the resumed cycle must start
  # from. Deliberately NOT `cycle-state.sh`'s `cycle_state_role` (that helper
  # returns "" for GATED and is shaped for human block-message text, not a
  # role-sequence lookup) — this is a distinct, resume-specific mapping.
  @spec resume_role_for_state(String.t()) :: String.t() | nil
  defp resume_role_for_state("GATED"), do: "reviewer"
  defp resume_role_for_state("REVIEWED"), do: "context-curator"
  defp resume_role_for_state("CURATED"), do: "committer"
  defp resume_role_for_state(_other), do: nil

  # Resolves a state's abstract "reviewer" target against the STACK-SPECIFIC
  # role name actually present in `roles` (role_sequence/1 emits
  # "reviewer-phoenix" or "reviewer-static", never a bare "reviewer") — never
  # hardcode either variant here.
  @spec resolve_resume_role(String.t(), [String.t()]) :: String.t() | nil
  defp resolve_resume_role("reviewer", roles) do
    Enum.find(roles, &(&1 == "reviewer-phoenix" or &1 == "reviewer-static"))
  end

  defp resolve_resume_role(role, roles), do: Enum.find(roles, &(&1 == role))

  # Determines whether `cwd` carries a valid resume checkpoint: a durable,
  # gate-clear, tree-matched record of a prior cycle that died AFTER the
  # gate went green but BEFORE the committer landed. See pitch "no
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
         true <- resume_head_unmoved?(cwd, opts) do
      {:resume, resume_role, state}
    else
      _ -> :full
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
  @spec resume_suffix([String.t()], String.t()) :: [String.t()]
  defp resume_suffix(roles, resume_role) do
    Enum.drop_while(roles, &(&1 != resume_role))
  end

  # Observability for a resumed cycle: one stderr line (always, names the
  # slug so the identity guard's decision is operator-visible) + one
  # best-effort cycle-log line appended under `resume_role` itself —
  # `resume_role` is always a real role from codegen-log's vocabulary
  # (planner*/developer-*/reviewer-*/context-curator/committer — see
  # shared/rules/_core/session-log.md § Event Schema), so the resume note
  # belongs to the role section it resumes into rather than an invented
  # pseudo-role codegen-log would refuse. Fail-loud-non-blocking: a
  # codegen-log failure here must never abort a resume that is otherwise
  # valid.
  @spec log_resume(String.t(), String.t(), run_opts()) :: :ok
  defp log_resume(resume_role, state, opts) do
    slug = Keyword.get(opts, :slug)

    IO.puts(
      :stderr,
      "codegen.loop: resuming at #{resume_role} (prior state #{state}, gate clear, tree matched, " <>
        "slug #{slug}) — skipping the completed prefix"
    )

    log_resume_fn = Keyword.get(opts, :log_resume_fn, &default_log_resume/2)
    log_resume_fn.(resume_role, state)
  end

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

    :ok
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
  # `:unknown` (the reviewer's output carried no parseable
  # `REVIEW_VERDICT:` sentinel — truncated response, crash mid-sentence, or
  # simply forgot it) is NEVER folded into the same "proceed" arm as
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
  defp handle_review(reviewer_role, review_result, rest, harness, ctx, opts, cycle) do
    max_cycles = Keyword.get(opts, :max_review_cycles, 1)

    case parse_review_verdict(review_result) do
      :changes_requested when cycle < max_cycles ->
        dev_role = dev_role_from_ctx(ctx)

        if is_nil(dev_role) do
          # No developer role in this cycle to route feedback to — proceed.
          advance_cycle_state_step("REVIEWED", ctx, opts)
          run_roles(rest, harness, ctx, opts)
        else
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

                with {:ok, review2, ctx} <- invoke_reviewer(reviewer_role, harness, ctx, opts) do
                  ctx = put_in(ctx, [:artifacts, reviewer_role], review2)
                  handle_review(reviewer_role, review2, rest, harness, ctx, opts, cycle + 1)
                end

              verdict ->
                {:error, "gate verdict=#{verdict} after review re-work (cycle #{cycle + 1})"}
            end
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

      :unknown when cycle < max_cycles ->
        handle_unparseable_review(reviewer_role, rest, harness, ctx, opts, cycle)

      :unknown ->
        {:error,
         "reviewer output carried no parseable REVIEW_VERDICT: sentinel after " <>
           "#{cycle + 1} attempt(s) — refusing to silently advance as approved. " <>
           "Last output: #{inspect(review_result["value"])}"}
    end
  end

  # `:unknown` re-work path: re-invoke the SAME reviewer once, explicitly
  # demanding the missing sentinel — no developer re-work, no gate re-run,
  # since nothing about the code changed; only the reviewer failed to state
  # its verdict. A second `:unknown` raises (see `handle_review/7`'s
  # `:unknown` catch-all) rather than looping indefinitely.
  defp handle_unparseable_review(reviewer_role, rest, harness, ctx, opts, cycle) do
    ctx =
      put_in(
        ctx,
        [:artifacts, :review_verdict_missing],
        "Your previous response did not end with a parseable `REVIEW_VERDICT: APPROVED` or " <>
          "`REVIEW_VERDICT: CHANGES_REQUESTED` line. Re-state your review, ending with exactly " <>
          "one of those two lines."
      )

    with {:ok, review2} <- invoke_with_retry(reviewer_role, harness, ctx, opts) do
      ctx = put_in(ctx, [:artifacts, reviewer_role], review2)
      handle_review(reviewer_role, review2, rest, harness, ctx, opts, cycle + 1)
    end
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
  # Budget-exhausted → FAIL LOUD (diverges from
  # `handle_review`'s proceed-on-exhaustion): the committer cannot Read/Edit
  # `context/*.md`, so handing it a known-bad doc is an unfixable dead-end
  # that used to compound into a dirty-tree retry loop.
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

  defp curator_doc_check_exhausted(ctx, cycle, violations) do
    write_terminal_marker(ctx.cwd, "context-curator doc check unresolved", "context-curator")

    {:error,
     "Turn-0 preflight found no inherited orientation-doc drift at HEAD #{ctx.base_head}; " <>
       "the violations below arrived with this cycle's own edits.\n" <>
       "context-curator doc check unresolved after #{cycle} cycle(s):\n#{violations}\n" <>
       "The committer cannot Read/Edit context/*.md (subagent-read-discipline denies it), " <>
       "so handing this violation onward would be an unfixable dead-end. Fix the orientation " <>
       "docs and re-run the cycle."}
  end

  # Turn-0 phase exhaustion formatter — sibling of `curator_doc_check_exhausted/3`
  # above (post-curator phase). Distinguishes the two in the returned
  # message: this violation was ALREADY present at HEAD (inherited), not
  # introduced by this cycle's own edits.
  defp turn0_repair_exhausted(ctx, cycle, violations) do
    write_terminal_marker(ctx.cwd, "orientation-doc preflight unresolved", "context-curator")

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
  # as `run_curator_doc_check`, not `handle_review`'s proceed-on-exhaustion):
  # an undeclared required env var is a real defect the app crashes on at
  # runtime.
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

  # Corpus sync — carries any *_cycle.jsonl present on refs/heads/corpus but
  # absent locally into codegen/logging/, BEFORE this cycle's own log is
  # minted. Codegen-only (codegen-log's own corpus_enabled sentinel no-ops
  # silently in every downstream project) and fail-loud-non-blocking: any
  # non-zero exit or missing binary is logged to stderr and swallowed —
  # never raises, never delays or blocks the cycle. See codegen-log's own
  # `corpus sync` header comment for the mechanism.
  @spec default_corpus_sync(String.t()) :: :ok
  defp default_corpus_sync(cwd) do
    if File.exists?(@codegen_log_bin) do
      {output, exit_code} =
        System.cmd(@codegen_log_bin, ["corpus", "sync"],
          stderr_to_stdout: true,
          env: [{"CODEGEN_DIR", @codegen_dir}, {"CODEGEN_LOG_PATH", nil}],
          cd: cwd
        )

      if exit_code != 0 do
        IO.puts(
          :stderr,
          "OrchestrationLoop: codegen-log corpus sync failed (#{exit_code}): #{output}"
        )
      end
    end

    :ok
  rescue
    e ->
      IO.puts(
        :stderr,
        "OrchestrationLoop: codegen-log corpus sync raised: #{Exception.message(e)}"
      )

      :ok
  end

  # Corpus publish — carries THIS cycle's own log (resolved via
  # CODEGEN_LOG_PATH, codegen-log's highest-precedence resolver) onto
  # refs/heads/corpus, at the cycle tail, on the ok path, the error path,
  # and a raise (called from an `after` block in run_body_from/6). Skips
  # cleanly when no log was ever minted (Process.get returns nil — e.g. a
  # unit test with no :slug opt). Codegen-only and fail-loud-non-blocking,
  # same posture as default_corpus_sync/1 above.
  @spec default_corpus_publish(String.t()) :: :ok
  defp default_corpus_publish(cwd) do
    case Process.get(@log_path_key) do
      nil ->
        :ok

      log_path ->
        if File.exists?(@codegen_log_bin) do
          {output, exit_code} =
            System.cmd(@codegen_log_bin, ["corpus", "publish"],
              stderr_to_stdout: true,
              env: [{"CODEGEN_DIR", @codegen_dir}, {"CODEGEN_LOG_PATH", log_path}],
              cd: cwd
            )

          if exit_code != 0 do
            IO.puts(
              :stderr,
              "OrchestrationLoop: codegen-log corpus publish failed (#{exit_code}): #{output}"
            )
          end
        end

        :ok
    end
  rescue
    e ->
      IO.puts(
        :stderr,
        "OrchestrationLoop: codegen-log corpus publish raised: #{Exception.message(e)}"
      )

      :ok
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

  defp parse_review_verdict(%{"value" => value}) when is_binary(value) do
    lines = String.split(value, "\n", trim: true)

    case List.last(lines) do
      "REVIEW_VERDICT: APPROVED" ->
        if Enum.count(lines, &String.starts_with?(&1, "REVIEW_VERDICT:")) == 1,
          do: :approved,
          else: :unknown

      "REVIEW_VERDICT: CHANGES_REQUESTED" ->
        if Enum.count(lines, &String.starts_with?(&1, "REVIEW_VERDICT:")) == 1,
          do: :changes_requested,
          else: :unknown

      _ ->
        :unknown
    end
  end

  defp parse_review_verdict(_), do: :unknown

  defp dev_role_from_ctx(ctx) do
    (ctx[:artifacts] || %{})
    |> Map.keys()
    |> Enum.find(fn k -> is_binary(k) and String.starts_with?(k, "developer-") end)
  end

  # Runs the gate once (developer already ran) and returns the verdict atom.
  defp run_gate_once(ctx, opts) do
    gate_fn = Keyword.get(opts, :gate_fn, &LoopGate.run_gate/2)
    {verdict, _cmd} = gate_fn.(ctx.cwd, gate_opts(opts, ctx))
    verdict
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
  end

  defp gate_opts(opts, ctx) when is_map(ctx) or is_nil(ctx) do
    opts
    |> Keyword.put_new(:cycle_log, Process.get(@log_path_key))
    |> Keyword.put_new(:session_id, gate_actor(ctx))
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

      with {:ok, result} <- invoke_with_retry(dev_role, harness, retry_ctx, opts) do
        ctx =
          retry_ctx
          |> put_in([:artifacts, dev_role], result)
          |> update_in([:artifacts], &Map.delete(&1, :escalated_model))

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

      cond do
        diff_trimmed == "" and untracked == "" ->
          ""

        byte_size(diff_out) > @rework_brief_max_bytes ->
          {stat_out, _status} =
            System.cmd("git", diff_args ++ ["--stat"], cd: cwd, stderr_to_stdout: true)

          "### Your current diff (uncommitted, authoritative) — TOO LARGE TO INLINE\n\n" <>
            "Diff is #{byte_size(diff_out)} bytes — too large to inline. Run " <>
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
  defp invoke_reviewer(reviewer_role, harness, ctx, opts) do
    set_fn = Keyword.get(opts, :review_file_set_fn, &default_review_file_set_fn/1)
    files = set_fn.(ctx.cwd)

    if files == "" and git_work_tree?(ctx.cwd) do
      {:error, "cycle produced no changes — nothing for the reviewer to review"}
    else
      ctx = put_in(ctx, [:artifacts, :review_file_set], files)

      with {:ok, result} <- invoke_with_retry(reviewer_role, harness, ctx, opts) do
        {:ok, result, ctx}
      end
    end
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
  # non-nil — a real git tree). Records a `{"ev":"committed"}` event (loop-
  # authored, never role-authored) and asserts on the loop's OWN pre/post
  # samples — never on the recorded event itself, which a bypassing role
  # could forge via the codegen-log CLI. `role != "committer"` moving HEAD
  # is a guard bypass (see the three known incidents this reproduces as
  # fixtures) — raise loud, naming the role and the sha, so the cycle fails
  # rather than silently shipping an unattributed commit.
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

    unless role == "committer" do
      raise "OrchestrationLoop: HEAD moved during #{role} (#{post_head}); only the committer writes history"
    end

    :ok
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

    # No-role-is-enforced-outside-its-own-turn (planner instance): a planner
    # is FORCED by role-retrospective-before-stop to end its turn on the
    # mandated `codegen-log --learned` tool call — sometimes with no
    # trailing assistant text, which call-dispatch classifies as
    # status:"failed" even though the planner's real deliverable (the typed
    # {"ev":"plan",...} event) already landed. Same seam
    # resolve_planner_plan!/2 uses one step later — reused here, not
    # redefined, so both reads agree on what "plan present" means.
    planner_plan_fn = Keyword.get(opts, :planner_plan_fn, &default_planner_plan/1)

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

    {model, effort} =
      case resolve_fixed_binding(role, harness, opts) do
        {fixed_model, fixed_effort} ->
          {fixed_model, fixed_effort}

        :none ->
          case get_in(ctx, [:artifacts, :escalated_model]) do
            {escalated_model, escalated_effort} -> {escalated_model, escalated_effort}
            _ -> resolve_fn.(role, harness)
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

    accumulate_telemetry(role, envelope, %{harness: harness, model: model, effort: effort})
    write_cycle_summary(cycle_id, ctx.cwd, role, seq, transcript, envelope)

    case envelope do
      %{"result" => %{"status" => "success"} = result} ->
        case check_budget(opts) do
          :ok -> {:ok, Map.put(result, "session_id", envelope["session_id"])}
          {:error, reason} -> {:error, reason}
        end

      %{"result" => %{"status" => "failed"} = result} ->
        plan = planner_plan_fn.(Process.get(@log_path_key))

        if planner_role?(role) and is_binary(plan) and String.trim(plan) != "" do
          case check_budget(opts) do
            :ok -> {:ok, Map.put(result, "session_id", envelope["session_id"])}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, result["reason"] || "role #{role} failed with no reason given"}
        end

      other ->
        raise "OrchestrationLoop: unexpected codegen-call envelope for role #{role}: #{inspect(other)}"
    end
  end

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
  the full pitch/plan prompt `build_prompt/2` would otherwise re-send. The
  resumed session already carries the role's full identity, plan, and prior
  tool-call history; re-sending the pitch would waste tokens re-deriving
  context the transcript already has.
  """
  @spec resume_prompt(String.t()) :: String.t()
  def resume_prompt(_role) do
    "Your previous turn was cut off by a transport error. The session's history above is " <>
      "your own work. Continue from where you stopped; do not redo completed work. Finish " <>
      "and emit your result JSON."
  end

  @doc false
  def build_prompt(role, ctx) do
    reason = get_in(ctx, [:artifacts, :last_failure_reason])

    base = ctx[:pitch] || ""

    # Thread the planner's ACTUAL plan (resolved+validated at role-result-store
    # time in run_roles/4, stashed at ctx.artifacts[:planner_plan] — read from
    # the typed {"ev":"plan",...} event via LoopGate.planner_plan/1, NOT the
    # envelope `result`'s `value`, which is the planner's final chat message
    # and can be a recap with no plan in it, and NOT re-parsed out of the
    # free-form ev:role body prose) to the developer AND the reviewer under
    # the exact `## Plan` heading their baked rules contract on, so each
    # works from what was actually planned instead of re-deriving scope from
    # the raw pitch (developer) or reviewing blind with vacuous plan-fulfillment
    # checks (reviewer — see pitch "reviewer checks bind to reality"). (This
    # is the real value: prior-role context threading — see structural gap
    # #6. We do NOT try to suppress "gold-plating" like SEO/OG/JSON-LD: that
    # is normal, harmless polish, not a defect — an earlier iteration
    # mis-treated it as one.) Static has no planner in its sequence, so this
    # is always absent there — the prompt stays the raw pitch, unchanged, for
    # both developer-static and reviewer-static.
    plan = get_in(ctx, [:artifacts, :planner_plan])

    base =
      if (developer_role?(role) or reviewer_role?(role)) and is_binary(plan) and
           String.trim(plan) != "" do
        base <> "\n\n" <> plan
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
          "settled: the plan above is unchanged and the approach was accepted. Do NOT " <>
          "re-explore the codebase, re-derive scope, or re-read files whose content is " <>
          "already in the diff. This is the uncommitted working tree — if something in it " <>
          "is not yours, it predates the cycle; leave it alone and fix only the fault named " <>
          "below, then re-verify.\n\n" <> brief
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

        verifier_notice = verifier_surface_notice(files)

        base <>
          file_section <>
          verifier_notice <>
          "\n\nReview these changes against normal reviewer checks (quality, security, " <>
          "silent-failure/Rule S, test coverage).\n\nEND your response with exactly one terminal line: " <>
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
  @pi_enforcement_ext_path Path.expand(
                             "../../../harnesses/pi/pi-extensions/enforcement",
                             __DIR__
                           )

  @doc """
  Resolves the B-bucket in-agent guard bundle flag for `harness`:

  - `"claude_code"` → `["--settings=@<claude-code-settings.json>"]`
  - `"pi"` → `["--extension=@<enforcement extension dir>"]`

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
  - `:pi_enforcement_ext_path` — override for testing (default: the built
    `harnesses/pi/pi-extensions/enforcement` directory)
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

  def guard_bundle_flag!("pi", opts) do
    path = Keyword.get(opts, :pi_enforcement_ext_path, @pi_enforcement_ext_path)

    unless File.dir?(path) do
      raise "OrchestrationLoop: pi enforcement extension not found at #{path} — refusing to run a role unguarded"
    end

    ["--extension=@#{path}"]
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
          env: [{"CG_ERR", err_path} | env],
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

  # `dispatch` carries the {harness, model, effort} tuple this specific
  # invocation actually requested — populated by `invoke_role/4` from the
  # SAME resolved values used to build the `codegen_call_fn.(...)` call, so
  # it can never drift from what was truly dispatched. Empty map (the /2
  # delegate above, and any other pre-existing caller) means "unknown",
  # never a fabricated tuple — `emit_loop_telemetry/1` reads it as an
  # optional field per role_entry.
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
        effort: Map.get(dispatch, :effort)
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
  defp write_cycle_summary(nil, _cwd, _role, _seq, _transcript, _envelope), do: :ok

  defp write_cycle_summary(cycle_id, cwd, role, seq, transcript, envelope) do
    usage = Map.get(envelope, "usage", %{})

    line =
      Jason.encode!(%{
        "role" => role,
        "seq" => seq,
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

    unless is_binary(binding["harness"]) and binding["harness"] in ["claude", "claude_code", "pi"] do
      raise "OrchestrationLoop: #{path} \"harness\" must be one of claude/claude_code/pi, got: #{inspect(binding["harness"])}"
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
