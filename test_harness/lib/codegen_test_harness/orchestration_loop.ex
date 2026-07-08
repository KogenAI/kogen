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

  alias CodegenTestHarness.{LoopGate, RoleResolver}

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

  @codegen_call_bin Path.expand("../../../codegen-call", __DIR__)
  @codegen_dir Path.expand("../../..", __DIR__)

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
    to `LoopGate.run_gate/2`
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

  Returns `:ok` on COMMITTED + clear gate. Returns `{:error, reason}` on
  any role failure (after one retry), a non-clear gate (after the gate-retry
  bound is exhausted — progress-based, or `:max_gate_retries` when no
  progress signature is available), or an unexpected envelope shape (raised,
  not returned — crash loud).
  """
  @spec run(run_opts()) :: :ok | {:error, String.t()}
  def run(opts) do
    harness = Keyword.fetch!(opts, :harness)
    stack = Keyword.fetch!(opts, :stack)
    cwd = Keyword.fetch!(opts, :cwd)
    pitch = Keyword.fetch!(opts, :pitch)

    roles = role_sequence(stack)
    ctx = %{cwd: cwd, pitch: pitch, artifacts: %{}, base_head: cycle_base_head(cwd)}

    Process.put(@transcript_seq_key, 0)
    Process.put(@cycle_id_key, Keyword.get(opts, :cycle_id))

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

  defp run_roles([role | rest], harness, ctx, opts) do
    with {:ok, result} <- invoke_with_retry(role, harness, ctx, opts) do
      ctx = put_in(ctx, [:artifacts, role], result)

      cond do
        developer_role?(role) ->
          run_format_step(ctx.cwd, opts)
          run_gate_then_continue(role, rest, harness, ctx, opts)

        role == "reviewer-phoenix" or role == "reviewer-static" ->
          handle_review(role, result, rest, harness, ctx, opts, 0)

        role == "context-curator" ->
          run_format_step(ctx.cwd, opts)
          advance_cycle_state_step("CURATED", ctx, opts)
          run_roles(rest, harness, ctx, opts)

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

    advanced? = String.trim(count_out) != "0"

    {diff_out, 0} =
      System.cmd("git", ["diff", base_head, "HEAD"], cd: cwd, stderr_to_stdout: true)

    diff_nonempty? = String.trim(diff_out) != ""

    unless advanced? and diff_nonempty? do
      raise "OrchestrationLoop: committer returned success and the tree is clean, but NO work was " <>
              "produced this cycle — HEAD did not advance past the cycle base (#{base_head}) with a " <>
              "non-empty diff. This is the no-op false-success the loop exists to prevent (loop_failed)."
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
          rework_ctx = put_in(ctx, [:artifacts, :review_feedback], feedback)

          with {:ok, dev_result} <- invoke_with_retry(dev_role, harness, rework_ctx, opts) do
            ctx = put_in(rework_ctx, [:artifacts, dev_role], dev_result)
            run_format_step(ctx.cwd, opts)

            case run_gate_once(ctx, opts) do
              :clear ->
                advance_cycle_state_step("GATED", ctx, opts)

                with {:ok, review2} <- invoke_with_retry(reviewer_role, harness, ctx, opts) do
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
    {verdict, _cmd} = gate_fn.(ctx.cwd, opts)
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
    case gate_fn.(ctx.cwd, opts) do
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
  # reason folded into context, then gives up.
  defp invoke_with_retry(role, harness, ctx, opts) do
    invoke_fn = Keyword.get(opts, :invoke_fn, &invoke_role/4)

    case invoke_fn.(role, harness, ctx, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        retry_ctx = put_in(ctx, [:artifacts, :last_failure_reason], reason)

        case invoke_fn.(role, harness, retry_ctx, opts) do
          {:ok, result} -> {:ok, result}
          {:error, reason2} -> {:error, "role #{role} failed twice: #{reason2}"}
        end
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
        {:ok, result}

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
        ) ++ [prompt]

    env =
      [
        {"CODEGEN_DIR", @codegen_dir},
        {"CODEGEN_BUILD_START_TS", Integer.to_string(System.system_time(:second))},
        {"CODEGEN_LOOP", "1"}
      ] ++ if(transcript, do: [{"CODEGEN_CALL_TRANSCRIPT_PATH", transcript}], else: [])

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
