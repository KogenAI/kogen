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

  alias CodegenTestHarness.{BuildLock, LoopGate, RoleResolver}

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

  # Roles whose returned envelope value is asserted for a
  # `### What I Learned This Step` retrospective block. Mirrors the deleted
  # `subagent-retrospective-guard` hook's exact matcher set. context-curator
  # and committer are intentionally excluded (matches the deleted hook).
  @retrospective_roles ~w(developer-phoenix-backend developer-phoenix-frontend planner-phoenix planner-static reviewer-phoenix reviewer-static)

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
  - `:realized_check_fn` — test seam: `(pitch, cwd -> {:ok, map} | {:error, reason})`
    — turn-0 preflight run AFTER role/gate preflights but BEFORE any role is
    invoked; defaults to `default_realized_check/2` (a single `codegen-call`
    against `harnesses/shared/prompt-bodies/realized-check.md` with a JSON
    schema, asking whether the pitch's requirements are already satisfied by
    the current tree). Fails CLOSED: only a `realized: true` +
    `confidence: "high"` + non-empty `evidence` verdict skips the role chain
    (returns `:ok` immediately, no role invoked); every other outcome —
    `realized: false`, low confidence, empty evidence, an unparseable
    envelope, or a non-zero exit — proceeds to the full `run_roles` cycle.
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
  - `:max_retrospective_cycles` — warm-resume attempts allowed to recover a
    missing `### What I Learned This Step` block from a developer/planner/
    reviewer role before giving up (default 1). Unlike `:max_env_var_cycles`
    / `:max_factcheck_cycles`, exhaustion NEVER fails the cycle — it soft-
    warns to stderr and proceeds. Replaces the dead-under-loop
    `subagent-retrospective-guard` SubagentStop hook (roles run as
    main-agent `codegen-call` invocations under the loop, so SubagentStop
    never fires — same reasoning as `run_format_step`). A cold re-invoke of
    the role cannot author an authentic retrospective (no memory of the
    work it did), so recovery warm-resumes the SAME session via
    `codegen-call --resume=<session_id>` instead of re-invoking cold.
  - `:retrospective_resume_fn` — test seam:
    `(role, session_id, ctx, opts -> {:ok, block} | {:error, reason})`,
    defaults to `default_retrospective_resume/4` (a warm `codegen-call
    --agent=<role> --resume=<session_id>` asking the role to add its
    omitted retrospective block).

  Returns `:ok` on COMMITTED + clear gate, OR immediately (before any role
  runs) when the turn-0 realized-check confirms the pitch's work already
  exists in the tree. Returns `{:error, reason}` on
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
    # key stays nil, and role_logged_retrospective?/2 degrades to false.
    # A present slug that fails to init is fatal: a cycle with no log of its
    # own would otherwise silently append its roles' sections into whatever
    # unrelated log happens to be newest on disk.
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

    if realized?(pitch, cwd, opts) do
      :ok
    else
      run_roles(roles, harness, ctx, opts)
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

  @realized_check_prompt_path Path.expand(
                                "../../../harnesses/shared/prompt-bodies/realized-check.md",
                                __DIR__
                              )

  @realized_check_schema Jason.encode!(%{
                           "type" => "object",
                           "required" => ["realized", "confidence", "evidence"],
                           "additionalProperties" => false,
                           "properties" => %{
                             "realized" => %{"type" => "boolean"},
                             "confidence" => %{"type" => "string", "enum" => ["high", "low"]},
                             "evidence" => %{"type" => "string"}
                           }
                         })

  # Turn-0 realized-check preflight: asks a single cheap LLM turn whether the
  # pitch's requirements are ALREADY satisfied by the current tree, BEFORE any
  # role is invoked (and paid for). Fails CLOSED — the default is "not
  # realized, run the full cycle": only a high-confidence, evidenced
  # realized:true verdict short-circuits the loop. Every other outcome
  # (realized:false, low confidence, empty evidence, unparseable envelope, or
  # a non-zero codegen-call exit) proceeds to the normal role chain. A false
  # skip would silently ship a pitch without doing its work — the exact
  # silent-wrong-output failure this loop exists to prevent — so asymmetric
  # caution is mandatory: only skip on unambiguous, cited evidence.
  defp realized?(pitch, cwd, opts) do
    check_fn = Keyword.get(opts, :realized_check_fn, &default_realized_check/2)

    case check_fn.(pitch, cwd) do
      {:ok, %{"realized" => true, "confidence" => "high", "evidence" => evidence}}
      when is_binary(evidence) and evidence != "" ->
        IO.puts(:stderr, "REALIZED — skipping chain (evidence: #{evidence})")
        true

      _other ->
        false
    end
  end

  defp default_realized_check(pitch, cwd) do
    unless File.exists?(@codegen_call_bin) do
      raise "OrchestrationLoop: codegen-call not found at #{@codegen_call_bin}"
    end

    unless File.exists?(@realized_check_prompt_path) do
      raise "OrchestrationLoop: realized-check prompt not found at #{@realized_check_prompt_path}"
    end

    schema_path = write_realized_check_schema!()

    args =
      [
        "--harness=claude_code",
        "--model=haiku",
        "--effort=low",
        "--system-prompt=@#{@realized_check_prompt_path}",
        "--json-schema=@#{schema_path}"
      ] ++ prompt_tail(pitch)

    env = [{"CODEGEN_DIR", @codegen_dir}]

    {output, exit_code} =
      System.cmd(@codegen_call_bin, args, stderr_to_stdout: true, env: env, cd: cwd)

    File.rm(schema_path)

    with 0 <- exit_code,
         {:ok, envelope} <- Jason.decode(output),
         %{"result" => %{"status" => "success", "value" => value}} <- envelope,
         true <- is_map(value) do
      {:ok, value}
    else
      _other -> {:error, "realized-check: no confirmed verdict (fail closed)"}
    end
  end

  defp write_realized_check_schema! do
    path =
      Path.join(
        System.tmp_dir!(),
        "codegen-realized-check-schema-#{:erlang.unique_integer([:positive])}.json"
      )

    File.write!(path, @realized_check_schema)
    path
  end

  # Runs each role in sequence up to (not including) the gate-dependent
  # tail (reviewer onward); the gate step is interleaved between the
  # developer role and the reviewer role.
  defp run_roles([], _harness, _ctx, _opts), do: :ok

  defp run_roles([role | rest], harness, ctx, opts) do
    with {:ok, result} <- invoke_with_retry(role, harness, ctx, opts) do
      ctx = put_in(ctx, [:artifacts, role], result)
      ctx = run_retrospective_step(role, ctx, opts)

      cond do
        developer_role?(role) ->
          run_format_step(ctx.cwd, opts)
          run_env_var_step(role, rest, harness, ctx, opts, 0)

        role == "reviewer-phoenix" or role == "reviewer-static" ->
          handle_review(role, result, rest, harness, ctx, opts, 0)

        role == "context-curator" ->
          run_format_step(ctx.cwd, opts)
          run_curator_doc_check(role, rest, harness, ctx, opts, 0)

        role == "committer" ->
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

        true ->
          run_roles(rest, harness, ctx, opts)
      end
    end
  end

  defp developer_role?(role), do: String.starts_with?(role, "developer-")

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
          rework_ctx = put_in(ctx, [:artifacts, :review_feedback], feedback)

          with {:ok, dev_result} <- invoke_with_retry(dev_role, harness, rework_ctx, opts) do
            ctx = put_in(rework_ctx, [:artifacts, dev_role], dev_result)
            ctx = run_retrospective_step(dev_role, ctx, opts)
            run_format_step(ctx.cwd, opts)

            case run_gate_once(ctx, opts) do
              :clear ->
                advance_cycle_state_step("GATED", ctx, opts)

                with {:ok, review2} <- invoke_with_retry(reviewer_role, harness, ctx, opts) do
                  ctx = put_in(ctx, [:artifacts, reviewer_role], review2)
                  ctx = run_retrospective_step(reviewer_role, ctx, opts)
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
        rework_ctx = put_in(ctx, [:artifacts, :env_var_violation], violations)

        with {:ok, dev_result} <- invoke_with_retry(dev_role, harness, rework_ctx, opts) do
          ctx = put_in(rework_ctx, [:artifacts, dev_role], dev_result)
          ctx = run_retrospective_step(dev_role, ctx, opts)
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

  # Retrospective warm-resume step. Replaces the dead-under-loop
  # `subagent-retrospective-guard` SubagentStop hook: under the loop, roles
  # run as main-agent `codegen-call` invocations with no SubagentStop event,
  # so this assertion has to be driven explicitly here (same reasoning as
  # `run_format_step`/`run_env_var_step`/`run_curator_doc_check`). Unlike those
  # siblings, this step NEVER fails the build — fatal-on-miss is off the
  # table (operator decision). A role not in `@retrospective_roles` (or
  # already carrying a valid block) is returned unchanged.
  #
  # On a missing block: a COLD re-invoke cannot author an authentic
  # retrospective (a fresh `codegen-call` process has no memory of the work
  # it did — it could only fabricate the block from `git diff`, which is
  # worse than no block at all). Recovery instead warm-resumes the SAME
  # session via `codegen-call --agent=<role> --resume=<session_id>`, asking
  # the still-warm role to add its omitted block. Bounded by
  # `:max_retrospective_cycles` (default 1); any residual (no session_id,
  # resume error, still-missing block after the budget) soft-warns to
  # stderr and proceeds — never returns `{:error, _}`, never raises.
  @spec run_retrospective_step(String.t(), map(), run_opts()) :: map()
  defp run_retrospective_step(role, ctx, opts) do
    if role in @retrospective_roles do
      do_run_retrospective_step(role, ctx, opts, 0)
    else
      ctx
    end
  end

  defp do_run_retrospective_step(role, ctx, opts, cycle) do
    result = get_in(ctx, [:artifacts, role])
    log_path = Process.get(@log_path_key)

    cond do
      role_logged_retrospective?(role, log_path) ->
        ctx

      cycle >= Keyword.get(opts, :max_retrospective_cycles, 1) ->
        IO.puts(
          :stderr,
          "retrospective: #{role} omitted '### What I Learned This Step'; warm-resume " <>
            "exhausted after #{cycle} cycle(s) — proceeding without it"
        )

        ctx

      true ->
        session_id = result && result["session_id"]

        if is_nil(session_id) or session_id == "" do
          IO.puts(
            :stderr,
            "retrospective: #{role} omitted '### What I Learned This Step'; no session_id " <>
              "available to warm-resume — proceeding without it"
          )

          ctx
        else
          resume_fn =
            Keyword.get(opts, :retrospective_resume_fn, &default_retrospective_resume/4)

          case resume_fn.(role, session_id, ctx, opts) do
            {:ok, _block} ->
              # The role wrote its retrospective to the CYCLE LOG (via
              # `codegen-log append <role> --learned`), not into this
              # envelope — re-check the log itself, never the resumed value.
              do_run_retrospective_step(role, ctx, opts, cycle + 1)

            {:error, reason} ->
              IO.puts(
                :stderr,
                "retrospective: #{role} omitted '### What I Learned This Step'; warm-resume " <>
                  "failed (#{reason}) — proceeding without it"
              )

              ctx
          end
        end
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
        env: [{"CODEGEN_DIR", @codegen_dir}],
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

  # True when THIS role wrote a retrospective block into THIS cycle's log —
  # the same bytes context-curator consumes (session-log.md § Subagent
  # Retrospective Convention). Reads the log directly: codegen-log is a
  # writer, not a reader, and adding a read subcommand is out of scope.
  # A malformed JSONL line is skipped, never fatal; a missing/nil log path
  # is simply "no block" — this step is contractually soft-warn-only.
  @spec role_logged_retrospective?(String.t(), String.t() | nil) :: boolean()
  defp role_logged_retrospective?(_role, nil), do: false

  defp role_logged_retrospective?(role, log_path) do
    case File.read(log_path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line ->
          case Jason.decode(line) do
            {:ok, %{"ev" => "role", "role" => ^role, "body" => body}} -> block_present?(body)
            {:ok, %{"ev" => "learned", "role" => ^role, "text" => text}} -> block_present?(text)
            _ -> false
          end
        end)

      {:error, _reason} ->
        false
    end
  end

  # A valid retrospective block requires the header AND at least one
  # non-blank content line after it — a bare/empty header (e.g. the header
  # text alone, no body) does not count.
  defp block_present?(text) when is_binary(text) do
    case String.split(text, "### What I Learned This Step", parts: 2) do
      [_before, after_header] ->
        after_header
        |> String.split("\n")
        |> Enum.any?(&(String.trim(&1) != ""))

      _ ->
        false
    end
  end

  defp block_present?(_text), do: false

  # Warm-resumes the role's ALREADY-RUN session (never a cold re-invoke) to
  # author the omitted retrospective block. Reuses the same argv/env shape
  # as `default_codegen_call/9` (guard bundle, CODEGEN_DIR, CODEGEN_LOOP=1)
  # plus `--resume=<session_id>`; no transcript path (this is a recovery
  # side-call, not a primary role invocation).
  defp default_retrospective_resume(role, session_id, ctx, opts) do
    unless File.exists?(@codegen_call_bin) do
      raise "OrchestrationLoop: codegen-call not found at #{@codegen_call_bin}"
    end

    resolve_fn = Keyword.get(opts, :resolve_fn, &RoleResolver.resolve_role/2)
    harness = Keyword.fetch!(opts, :harness)
    {model, effort} = resolve_fn.(role, harness)

    args =
      [
        "--harness=#{harness}",
        "--model=#{model}",
        "--effort=#{effort}",
        "--agent=#{role}",
        "--resume=#{session_id}"
      ] ++
        guard_bundle_flag!(harness, opts) ++
        prompt_tail(
          "You omitted your '### What I Learned This Step' block. Add it to the cycle log " <>
            "now by running: codegen-log append #{role} --learned \"<your learnings>\" — " <>
            "nothing else."
        )

    env =
      [
        {"CODEGEN_DIR", @codegen_dir},
        {"CODEGEN_BUILD_START_TS", Integer.to_string(System.system_time(:second))},
        {"CODEGEN_LOOP", "1"}
      ] ++ log_path_env()

    {output, exit_code} =
      System.cmd(@codegen_call_bin, args, stderr_to_stdout: true, env: env, cd: ctx.cwd)

    if exit_code != 0 do
      {:error,
       "codegen-call exited #{exit_code}: #{String.slice(output, max(String.length(output) - 400, 0), 400)}"}
    else
      case Jason.decode(output) do
        {:ok, %{"result" => %{"status" => "success", "value" => value}} = envelope}
        when is_binary(value) ->
          # Warm-resume calls burn real model turns just like a primary role
          # invocation — fold their cost/tokens into the same benchmark totals
          # `invoke_role/4` accumulates, so a cycle's aggregated `type:result`
          # line reflects the full spend (never under-reports recovery cost).
          accumulate_telemetry(role, envelope)

          if role_logged_retrospective?(role, Process.get(@log_path_key)) do
            {:ok, value}
          else
            {:error, "resumed role still omitted the retrospective block"}
          end

        {:ok, other} ->
          {:error, "unexpected resume envelope: #{inspect(other)}"}

        {:error, reason} ->
          {:error, "malformed resume envelope JSON: #{inspect(reason)}"}
      end
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
          retry_ctx = put_in(ctx, [:artifacts, :last_failure_reason], reason)

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

    case invoke_fn.(role, harness, ctx, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        log_died(role, "interrupted", reason, opts)
        retry_ctx = put_in(ctx, [:artifacts, :last_failure_reason], reason)

        case invoke_fn.(role, harness, retry_ctx, opts) do
          {:ok, result} ->
            {:ok, result}

          {:error, reason2} ->
            log_died(role, "aborted", reason2, opts)
            {:error, "role #{role} failed twice: #{reason2}"}
        end
    end
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

  `status`:
  - `"success"` → `{:ok, envelope["result"]}`
  - `"failed"` → `{:error, reason}` (reason from `result.reason`, or a
    generic message if absent)
  - `"clarifying_question"` → `{:error, reason}` (the loop cannot answer
    interactively; surfaced as a failure)
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

    # Default threads ctx.cwd into the codegen-call so the role's agent runs IN
    # the project directory. dispatch.sh cd's to test_harness to run mix, so
    # WITHOUT this every role would edit the wrong directory (loop bug #3).
    # The /6 seam signature is preserved for test overrides. `role` is bound
    # into the closure and threaded to default_codegen_call as the new
    # trailing `agent` arg — native `claude --agent <role>` invocation.
    codegen_call_fn =
      Keyword.get(opts, :codegen_call_fn, fn h, m, e, sp, tools, pr ->
        default_codegen_call(ctx.cwd, h, m, e, sp, tools, pr, transcript, role)
      end)

    {model, effort} = resolve_fn.(role, harness)

    prompt = build_prompt(role, ctx)

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

      %{"result" => %{"status" => "clarifying_question"} = result} ->
        {:error, "role #{role} asked a clarifying question: #{result["clarifying_question"]}"}

      other ->
        raise "OrchestrationLoop: unexpected codegen-call envelope for role #{role}: #{inspect(other)}"
    end
  end

  @doc false
  def build_prompt(role, ctx) do
    reason = get_in(ctx, [:artifacts, :last_failure_reason])

    base = ctx[:pitch] || ""

    # Thread the planner's plan to the developer so it implements what was actually
    # planned instead of re-deriving scope from the raw pitch. (This is the real
    # value: prior-role context threading — see structural gap #6. We do NOT try to
    # suppress "gold-plating" like SEO/OG/JSON-LD: that is normal, harmless polish,
    # not a defect — an earlier iteration mis-treated it as one.)
    plan = planner_plan(ctx)

    base =
      if developer_role?(role) and is_binary(plan) and String.trim(plan) != "" do
        base <> "\n\n## Implementation plan (from the planner)\n\n" <> plan
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

    # Reviewers must emit a machine-readable verdict the loop can act on (#7).
    base =
      if role == "reviewer-phoenix" or role == "reviewer-static" do
        base <>
          "\n\nThere is no `## Files Modified` section this cycle; the developer's entire " <>
          "change is sitting UNCOMMITTED in the project's working tree. Derive the " <>
          "authoritative changed set yourself: run `git diff HEAD` for tracked modifications " <>
          "plus `git status --porcelain` for new/untracked files, then review THAT diff " <>
          "against normal reviewer checks (quality, security, silent-failure/Rule S, test " <>
          "coverage).\n\nEND your response with a line exactly `REVIEW_VERDICT: APPROVED` if the change is " <>
          "acceptable, or `REVIEW_VERDICT: CHANGES_REQUESTED` followed by a short, specific, " <>
          "actionable list of required changes if not."
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

  # Extracts the planner's plan text from ctx.artifacts (static or phoenix
  # planner), or nil if no planner has run yet.
  defp planner_plan(ctx) do
    artifacts = ctx[:artifacts] || %{}

    ["planner-static", "planner-phoenix"]
    |> Enum.find_value(fn key ->
      case Map.get(artifacts, key) do
        %{"value" => v} when is_binary(v) ->
          v

        # fail-loud-exempt: absent planner (nil) or non-string value is a
        # legitimate "no plan to thread" — the developer falls back to the raw
        # pitch. Optional context enrichment, not a required contract.
        _ ->
          nil
      end
    end)
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
  as an option by `codegen-call`'s `OptionParser`. Shared by both
  `codegen-call` invocation sites (main role call + realized-check).
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
         agent
       ) do
    unless File.exists?(@codegen_call_bin) do
      raise "OrchestrationLoop: codegen-call not found at #{@codegen_call_bin}"
    end

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
        guard_bundle_flag!(harness) ++
        if(allowed_tools && allowed_tools != "",
          do: ["--allowed-tools=#{allowed_tools}"],
          else: []
        ) ++ prompt_tail(prompt)

    env =
      [
        {"CODEGEN_DIR", @codegen_dir},
        {"CODEGEN_BUILD_START_TS", Integer.to_string(System.system_time(:second))},
        {"CODEGEN_LOOP", "1"}
      ] ++
        if(transcript, do: [{"CODEGEN_CALL_TRANSCRIPT_PATH", transcript}], else: []) ++
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
