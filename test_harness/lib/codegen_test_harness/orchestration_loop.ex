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
  - `:gate_preflight_fn` — test seam: `(cwd -> resolved)` — resolves the app
    gate at turn 0 before any role runs; defaults to `LoopGate.decide_gate/1`
  - `:preflight_probe_fn` — test seam: `(cwd -> raw_output)` — resolves the
    full set of installed `--agent` role names at turn 0, before any role
    runs; defaults to `default_preflight_probe/1` (a single sentinel
    `codegen-call --agent <bogus>` call parsing claude's "Available agents:"
    error text — zero model turns)
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
  - `:curator_doc_check_fn` — test seam: `(cwd -> {:clean} | {:violations, String.t()})`,
    defaults to `default_curator_doc_scan/1`. Runs TWO checks after the
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
    Edit/Write/MultiEdit) never sees. Violations from either check are
    joined into one message. Empty changed-docs AND clean index-parity →
    `{:clean}` without shelling either scan. Runs after the context-curator
    role, replacing the dead-under-loop `context-factcheck-curator-stop`
    SubagentStop hook (roles run as main-agent `codegen-call` invocations
    under the loop, so SubagentStop never fires here — same reasoning as
    `run_format_step`) and the commit-time `context-index-parity` hook
    (which only ever dead-ended the committer, which cannot Read/Edit
    `context/*.md`).
  - `:max_curator_doc_cycles` — context-curator re-invokes allowed after a
    curator-doc violation (factcheck or index-parity) before giving up
    (default 1). Diverges from `:max_review_cycles` (which proceeds on
    budget exhaustion): exhaustion fails the cycle LOUD instead of
    proceeding — the committer cannot Read/Edit `context/*.md`, so handing
    it a known-bad doc is an unfixable dead-end that used to deadlock as a
    compounding dirty-tree retry.
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
  - `:max_env_var_cycles` — developer re-invokes allowed after an env-var
    violation before giving up (default 1). Exhaustion fails the cycle LOUD
    (same posture as `:max_curator_doc_cycles`, not `:max_review_cycles`'s
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
  Returns `:ok` on COMMITTED + clear gate. Returns `{:error, reason}` on
  any role failure (after one retry), a non-clear gate (after the gate-retry
  bound is exhausted — progress-based, or `:max_gate_retries` when no
  progress signature is available), or an unexpected envelope shape (raised,
  not returned — crash loud).
  """
  @spec run(run_opts()) :: :ok | {:error, String.t()}
  def run(opts) do
    cwd = Keyword.fetch!(opts, :cwd)

    if build_lock_bypassed?() do
      run_body(opts)
    else
      lock_path = Keyword.get(opts, :lock_path, default_lock_path(cwd))
      pid_alive_fn = Keyword.get(opts, :pid_alive_fn, &BuildLock.default_pid_alive?/1)

      case BuildLock.acquire(lock_path, "solo", pid_alive_fn) do
        :ok ->
          try do
            case refuse_if_orphan(cwd, opts) do
              :ok -> run_body(opts)
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

    roles = role_sequence(stack)
    ctx = %{cwd: cwd, pitch: pitch, artifacts: %{}, base_head: cycle_base_head(cwd)}

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
        log_init_fn = Keyword.get(opts, :log_init_fn, &default_log_init/2)
        Process.put(@log_path_key, log_init_fn.(slug, cwd))
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

    run_roles(roles, harness, ctx, opts)
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

  defp run_roles([role | rest], harness, ctx, opts) do
    with {:ok, result} <- invoke_with_retry(role, harness, ctx, opts) do
      ctx = put_in(ctx, [:artifacts, role], result)

      # No-developer-invoked-without-its-plan: immediately after a planner
      # role finishes, lift its ACTUAL plan (the `ev:role` body it wrote to
      # the cycle log — hook-guaranteed non-blank by
      # stop-verify-planner-gate.sh) rather than trusting the envelope
      # `result`'s `value` (that's the planner's final CHAT MESSAGE, which
      # can be a recap with no plan in it at all — see pitch
      # no-ship-on-a-gate-that-didnt-grade-this-tree... no,
      # no-developer-invoked-without-its-plan). A blank plan, or an
      # AMBIGUOUS one (a re-run left 2+ `## Plan` sections in the joined
      # body — gate-select.sh's first-gate-json-wins scan would then gate on
      # a DIFFERENT plan than the one threaded here), raises here — one role
      # in, before a developer is ever invoked on nothing.
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

        role == "context-curator" ->
          run_format_step(ctx.cwd, opts)
          run_curator_doc_check(role, rest, harness, ctx, opts, 0)

        true ->
          run_roles(rest, harness, ctx, opts)
      end
    end
  end

  defp developer_role?(role), do: String.starts_with?(role, "developer-")

  defp planner_role?(role), do: String.starts_with?(role, "planner-")

  # Resolves the planner's plan text for threading into build_prompt/2, via
  # the :planner_plan_fn seam (default reads the real cycle log through
  # LoopGate.planner_body/1 + extract_plan_section/1). Fail-closed: a blank
  # plan, or a body carrying more than one `## Plan` section (a planner
  # retry left two joined bodies — see run_roles/4 comment), raises
  # immediately rather than letting a developer run with no plan or an
  # ambiguous one.
  defp resolve_planner_plan!(role, opts) do
    plan_fn = Keyword.get(opts, :planner_plan_fn, &default_planner_plan/1)
    log_file = Process.get(@log_path_key)
    body = plan_fn.(log_file)

    case extract_plan_section(body) do
      {:ok, plan} ->
        plan

      {:error, :blank} ->
        raise "OrchestrationLoop: #{role} produced no ## Plan body in cycle log " <>
                "#{inspect(log_file)} — refusing to invoke a developer with no plan"

      {:error, {:ambiguous, count}} ->
        raise "OrchestrationLoop: planner body carries #{count} ## Plan sections in cycle log " <>
                "#{inspect(log_file)} — refusing to guess which plan the developer should implement"
    end
  end

  defp default_planner_plan(log_file), do: LoopGate.planner_body(log_file)

  # Slices the `## Plan` section out of a planner's role body: from the
  # `## Plan` heading up to (not including) the next top-level `## ` heading,
  # or the whole body when no `## Plan` heading is present at all (the same
  # tolerance gate-select.sh's own scanners apply — some planner prose omits
  # the sub-heading and the whole body IS the plan). More than one `## Plan`
  # heading (a joined multi-attempt body) is ambiguous — see resolve_planner_plan!/2.
  @spec extract_plan_section(String.t()) ::
          {:ok, String.t()} | {:error, :blank} | {:error, {:ambiguous, pos_integer()}}
  defp extract_plan_section(body) when not is_binary(body) or body == "" do
    {:error, :blank}
  end

  defp extract_plan_section(body) do
    lines = String.split(body, "\n")
    plan_heading_count = Enum.count(lines, &(&1 == "## Plan"))

    cond do
      plan_heading_count > 1 ->
        {:error, {:ambiguous, plan_heading_count}}

      plan_heading_count == 0 ->
        if String.trim(body) == "" do
          {:error, :blank}
        else
          {:ok, body}
        end

      true ->
        {_, start_idx} = Enum.find(Enum.with_index(lines), fn {l, _} -> l == "## Plan" end)

        rest = Enum.slice(lines, start_idx, length(lines) - start_idx)

        # Drop everything from the NEXT top-level "## " heading onward (but
        # keep the "## Plan" heading line itself at index 0).
        [_plan_heading | tail] = rest

        tail_before_next_h2 =
          Enum.take_while(tail, fn l -> not String.starts_with?(l, "## ") end)

        section = Enum.join(["## Plan" | tail_before_next_h2], "\n")

        if String.trim(section) == "" do
          {:error, :blank}
        else
          {:ok, section}
        end
    end
  end

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
  # (restamped `gate-result.json` now matches). Non-clear → re-invoke the
  # SAME developer role with the gate failure folded into context (mirrors
  # `do_gate_loop/9`'s rework shape), then recurse into
  # `ensure_gate_graded_this_tree!/5` for another match check + gate cycle.
  # No developer role in this cycle's artifacts (should not happen in
  # practice — a developer always runs before the committer in both role
  # sequences) → treat as exhausted rather than crash on a nil dev_role.
  defp rework_final_gate(ctx, rest, harness, opts, cycle) do
    gate_fn = Keyword.get(opts, :gate_fn, &LoopGate.run_gate/2)

    case gate_fn.(ctx.cwd, gate_opts(opts)) do
      {:clear, _gate_cmd} ->
        run_committer(ctx, rest, harness, opts)

      {:failed, _gate_cmd} ->
        dev_role = dev_role_from_ctx(ctx)

        if is_nil(dev_role) do
          {:error,
           "pre-commit re-gate failed and no developer role is present in this cycle's " <>
             "artifacts to route rework to (loop_failed, never a false loop_committed)."}
        else
          reason = gate_failure_reason(ctx.cwd)
          brief = capture_rework_brief(ctx.cwd, opts)

          retry_ctx =
            ctx
            |> put_in([:artifacts, :last_failure_reason], reason)
            |> put_in([:artifacts, :rework_brief], brief)

          with {:ok, result} <- invoke_with_retry(dev_role, harness, retry_ctx, opts) do
            ctx = put_in(retry_ctx, [:artifacts, dev_role], result)
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
  # APPROVED / unparseable → advance REVIEWED and continue. CHANGES_REQUESTED (within
  # :max_review_cycles, default 1) → re-invoke the developer with the reviewer's
  # feedback, re-format, re-gate, re-review, and recurse. Budget-exhausted → proceed
  # (don't wedge the cycle forever) but the state still records REVIEWED.
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

      _verdict ->
        # :approved, :unknown, or CHANGES_REQUESTED with budget exhausted.
        advance_cycle_state_step("REVIEWED", ctx, opts)
        run_roles(rest, harness, ctx, opts)
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
  # CURATED and continue. Violations within `:max_curator_doc_cycles` (default
  # 1) → fold the combined violation list into context, re-invoke the
  # context-curator (the last role that CAN edit `context/*.md`), re-format,
  # re-scan, recurse. Budget-exhausted → FAIL LOUD (diverges from
  # `handle_review`'s proceed-on-exhaustion): the committer cannot Read/Edit
  # `context/*.md`, so handing it a known-bad doc is an unfixable dead-end
  # that used to compound into a dirty-tree retry loop.
  defp run_curator_doc_check(curator_role, rest, harness, ctx, opts, cycle) do
    max_cycles = Keyword.get(opts, :max_curator_doc_cycles, 1)

    case run_curator_doc_scan(ctx.cwd, opts) do
      {:clean} ->
        advance_cycle_state_step("CURATED", ctx, opts)
        run_roles(rest, harness, ctx, opts)

      {:violations, violations} when cycle < max_cycles ->
        rework_ctx = put_in(ctx, [:artifacts, :curator_doc_violations], violations)

        with {:ok, curator_result} <- invoke_with_retry(curator_role, harness, rework_ctx, opts) do
          ctx = put_in(rework_ctx, [:artifacts, curator_role], curator_result)
          run_format_step(ctx.cwd, opts)
          run_curator_doc_check(curator_role, rest, harness, ctx, opts, cycle + 1)
        end

      {:violations, violations} ->
        {:error,
         "context-curator doc check unresolved after #{cycle} cycle(s):\n#{violations}\n" <>
           "The committer cannot Read/Edit context/*.md (subagent-read-discipline denies it), " <>
           "so handing this violation onward would be an unfixable dead-end. Fix the orientation " <>
           "docs and re-run the cycle."}
    end
  end

  # Dispatches the `:curator_doc_check_fn` test seam; defaults to
  # `default_curator_doc_scan/1` (the real shelled scans).
  defp run_curator_doc_scan(cwd, opts) do
    scan_fn = Keyword.get(opts, :curator_doc_check_fn, &default_curator_doc_scan/1)
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
  defp default_curator_doc_scan(cwd) do
    unless File.exists?(@index_parity_scan_lib) do
      raise "OrchestrationLoop: context-index-parity-scan.sh not found at #{@index_parity_scan_lib}"
    end

    unless File.exists?(@factcheck_scan_lib) do
      raise "OrchestrationLoop: context-factcheck-scan.sh not found at #{@factcheck_scan_lib}"
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

    combine_curator_doc_results(index_parity_result, factcheck_result)
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
  # continue to the gate. Violations within `:max_env_var_cycles` (default
  # 1) → fold the undocumented-var list into context, re-invoke the SAME
  # developer role (the one that can edit `.env.sample`/`.env.prod.sample`),
  # re-format, re-scan, recurse. Budget-exhausted → FAIL LOUD (same posture
  # as `run_curator_doc_check`, not `handle_review`'s proceed-on-exhaustion):
  # an undeclared required env var is a real defect the app crashes on at
  # runtime.
  defp run_env_var_step(dev_role, rest, harness, ctx, opts, cycle) do
    max_cycles = Keyword.get(opts, :max_env_var_cycles, 1)

    case run_env_var_scan(ctx.cwd, opts) do
      {:clean} ->
        run_gate_then_continue(dev_role, rest, harness, ctx, opts)

      {:violations, violations} when cycle < max_cycles ->
        brief = capture_rework_brief(ctx.cwd, opts)

        rework_ctx =
          ctx
          |> put_in([:artifacts, :env_var_violation], violations)
          |> put_in([:artifacts, :rework_brief], brief)

        with {:ok, dev_result} <- invoke_with_retry(dev_role, harness, rework_ctx, opts) do
          ctx = put_in(rework_ctx, [:artifacts, dev_role], dev_result)
          run_format_step(ctx.cwd, opts)
          run_env_var_step(dev_role, rest, harness, ctx, opts, cycle + 1)
        end

      {:violations, violations} ->
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
  # its resolved path (printed on stdout). Idempotent: re-init on an
  # existing slug prints that log's path and exits 0, so this is safe to
  # call unconditionally at cycle start (including on a resumed/retried
  # run). A non-zero exit is fatal — a cycle with no log of its own would
  # otherwise silently append its roles' sections into whatever unrelated
  # log happens to be newest on disk.
  @spec default_log_init(String.t(), String.t()) :: String.t()
  defp default_log_init(slug, cwd) do
    unless File.exists?(@codegen_log_bin) do
      raise "OrchestrationLoop: codegen-log not found at #{@codegen_log_bin}"
    end

    {output, exit_code} =
      System.cmd(@codegen_log_bin, ["init", "--slug", slug],
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

  defp parse_review_verdict(%{"value" => v}) when is_binary(v) do
    cond do
      Regex.match?(~r/REVIEW_VERDICT:\s*CHANGES_REQUESTED/i, v) -> :changes_requested
      Regex.match?(~r/REVIEW_VERDICT:\s*APPROVED/i, v) -> :approved
      true -> :unknown
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
    {verdict, _cmd} = gate_fn.(ctx.cwd, gate_opts(opts))
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
  # default_log_init/2 at cycle start, or nil when no log was initialized,
  # e.g. most unit tests). Adds a key only; never overwrites a :cycle_log a
  # test already supplied in opts.
  @spec gate_opts(run_opts()) :: run_opts()
  defp gate_opts(opts) do
    Keyword.put_new(opts, :cycle_log, Process.get(@log_path_key))
  end

  # Hard ceiling backstop: even with continuous progress, a run/1 cycle never
  # re-invokes the developer for gate failures more than this many times.
  @gate_progress_ceiling 15

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
    case gate_fn.(ctx.cwd, gate_opts(opts)) do
      {:clear, _gate_cmd} ->
        advance_cycle_state_step("GATED", ctx, opts)

        # A developer gate failure is not the NEXT role's "previous attempt"
        # — once the gate goes clear, drop the stale reason so it never
        # leaks into the reviewer (or any later role) prompt as a fault that
        # isn't theirs (pitch "reviewer handoff names the files under
        # review").
        ctx = update_in(ctx, [:artifacts], &Map.delete(&1, :last_failure_reason))
        run_roles(rest, harness, ctx, opts)

      {:failed, _gate_cmd} ->
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

          retry_ctx =
            ctx
            |> put_in([:artifacts, :last_failure_reason], reason)
            |> put_in([:artifacts, :rework_brief], brief)

          with {:ok, result} <- invoke_with_retry(dev_role, harness, retry_ctx, opts) do
            ctx = put_in(retry_ctx, [:artifacts, dev_role], result)
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
          {:error, "gate verdict=failed after #{attempt + 1} developer attempt(s)"}
        end

      {other, _gate_cmd} ->
        raise "OrchestrationLoop: unexpected gate verdict #{inspect(other)}"
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
  # advance_cycle_state/5, threading the session id + active step log from
  # ctx/opts when present (empty string when absent — cycle-state.sh
  # tolerates "").
  defp advance_cycle_state_step(state, ctx, opts) do
    advance_fn = Keyword.get(opts, :advance_cycle_state_fn, &advance_cycle_state/5)
    step_log = Keyword.get(opts, :step_log, "")
    session_id = Keyword.get(opts, :session_id, "")
    verdict = if state == "GATED", do: "clear", else: ""

    advance_fn.(state, step_log, session_id, verdict, ctx.cwd)
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
    do_invoke_attempt(role, harness, ctx, opts, invoke_fn, 1)
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
  # failed. Beyond the list, the last value repeats.
  defp backoff_ms(attempt) do
    delays = [15_000, 60_000, 120_000]
    Enum.at(delays, attempt - 1, List.last(delays))
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

  `status`:
  - `"success"` → `{:ok, envelope["result"]}`
  - `"failed"` → `{:error, reason}` (reason from `result.reason`, or a
    generic message if absent)
  - anything else → raises (crash loud — unexpected envelope shape)
  """
  @spec invoke_role(String.t(), harness(), map(), run_opts()) ::
          {:ok, map()} | {:error, String.t()}
  def invoke_role(role, harness, ctx, opts) do
    resolve_fn = Keyword.get(opts, :resolve_fn, &RoleResolver.resolve_role/2)

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
          cold_session_id
        )
      end)

    {model, effort} = resolve_fn.(role, harness)

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

    accumulate_telemetry(role, envelope)
    write_cycle_summary(cycle_id, ctx.cwd, role, seq, transcript, envelope)

    case envelope do
      %{"result" => %{"status" => "success"} = result} ->
        {:ok, Map.put(result, "session_id", envelope["session_id"])}

      %{"result" => %{"status" => "failed", "reason" => reason}} ->
        {:error, reason || "role #{role} failed with no reason given"}

      other ->
        raise "OrchestrationLoop: unexpected codegen-call envelope for role #{role}: #{inspect(other)}"
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
    # time in run_roles/4, stashed at ctx.artifacts[:planner_plan] — NOT the
    # envelope `result`'s `value`, which is the planner's final chat message
    # and can be a recap with no plan in it) to the developer under the exact
    # `## Plan` heading developer.md contracts on, so it implements what was
    # actually planned instead of re-deriving scope from the raw pitch. (This
    # is the real value: prior-role context threading — see structural gap
    # #6. We do NOT try to suppress "gold-plating" like SEO/OG/JSON-LD: that
    # is normal, harmless polish, not a defect — an earlier iteration
    # mis-treated it as one.) Static has no planner in its sequence, so this
    # is always absent there — the prompt stays the raw pitch, unchanged.
    plan = get_in(ctx, [:artifacts, :planner_plan])

    base =
      if developer_role?(role) and is_binary(plan) and String.trim(plan) != "" do
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

    # On a factcheck re-work pass, thread the violation list to the curator.
    fv = get_in(ctx, [:artifacts, :factcheck_violations])

    base =
      if role == "context-curator" and is_binary(fv) and String.trim(fv) != "" do
        base <>
          "\n\n## Factcheck violations to fix (re-work)\n\n" <>
          fv <> "\n\nFix these in the working tree; do not introduce unrelated changes."
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

        base <>
          file_section <>
          "\n\nReview these changes against normal reviewer checks (quality, security, " <>
          "silent-failure/Rule S, test coverage).\n\nEND your response with a line exactly " <>
          "`REVIEW_VERDICT: APPROVED` if the change is acceptable, or " <>
          "`REVIEW_VERDICT: CHANGES_REQUESTED` followed by a short, specific, actionable list " <>
          "of required changes if not."
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
         cold_session_id
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
        {"CODEGEN_LOOP", "1"}
      ] ++
        if(transcript, do: [{"CODEGEN_CALL_TRANSCRIPT_PATH", transcript}], else: []) ++
        if(resume_session_id && resume_session_id != "",
          do: [{"CODEGEN_RESUME_ATTEMPT", resume_session_id}],
          else: []
        ) ++
        log_path_env()

    {output, exit_code} =
      System.cmd(@codegen_call_bin, args, stderr_to_stdout: true, env: env, cd: cwd)

    # A non-zero codegen-call exit is an OPERATIONAL failure (transient claude
    # SIGTERM/exit 143, rate-limit kill, network blip) — NOT a programming error.
    # Return a synthetic failed envelope so invoke_with_retry/4 retries the role
    # ONCE instead of crashing the whole multi-role cycle. A genuinely broken
    # role still fails cleanly (failed status after the retry), never a raw crash
    # that discards all prior role work.
    if exit_code != 0 do
      %{
        "result" => %{
          "status" => "failed",
          "reason" =>
            "codegen-call exited #{exit_code} (transient?): #{String.slice(output, max(String.length(output) - 400, 0), 400)}"
        }
      }
    else
      # Malformed JSON on a zero exit IS an unexpected contract violation — crash loud.
      Jason.decode!(output)
    end
  end

  @doc """
  Advances `codegen/gate-pending/cycle-state.json` for `project_dir` to
  `state` (one of `CYCLE_STATE_ORDER`: GATED, REVIEWED, CURATED,
  COMMITTED) via `cycle-state.sh`'s `write_cycle_state`. `verdict` is
  meaningful only for `"GATED"` — pass `""` for other states.
  """
  @spec advance_cycle_state(String.t(), String.t(), String.t(), String.t(), String.t()) :: :ok
  def advance_cycle_state(state, step_log, session_id, verdict, project_dir) do
    unless File.exists?(@cycle_state_lib) do
      raise "OrchestrationLoop: cycle-state.sh not found at #{@cycle_state_lib}"
    end

    script =
      "source #{shell_quote(@cycle_state_lib)} && write_cycle_state " <>
        Enum.map_join([state, step_log, session_id, verdict, project_dir], " ", &shell_quote/1)

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
  def accumulate_telemetry(role, %{"usage" => usage}) when is_map(usage) do
    acc = get_telemetry()

    role_entry = %{
      cost_usd: t_num(usage["cost_usd"]),
      input_tokens: t_int(usage["input_tokens"]),
      output_tokens: t_int(usage["output_tokens"]),
      cache_read_tokens: t_int(usage["cache_read_input_tokens"]),
      cache_creation_tokens: t_int(usage["cache_creation_input_tokens"]),
      num_turns: t_int(usage["num_turns"])
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

  def accumulate_telemetry(_role, _envelope), do: :ok

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
        "transcript" => transcript
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
end
