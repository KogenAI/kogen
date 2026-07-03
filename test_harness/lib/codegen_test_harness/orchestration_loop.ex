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
  @static_roles ~w(developer-static reviewer-static context-curator committer)

  @cycle_state_lib Path.expand(
                     "../../../harnesses/claude/hooks/lib/cycle-state.sh",
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
    to `LoopGate.run_gate/2`
  - `:max_gate_retries` — developer re-runs allowed after a non-clear gate
    before giving up (default 1)

  Returns `:ok` on COMMITTED + clear gate. Returns `{:error, reason}` on
  any role failure (after one retry), a non-clear gate (after
  `:max_gate_retries` developer re-runs), or an unexpected envelope shape
  (raised, not returned — crash loud).
  """
  @spec run(run_opts()) :: :ok | {:error, String.t()}
  def run(opts) do
    harness = Keyword.fetch!(opts, :harness)
    stack = Keyword.fetch!(opts, :stack)
    cwd = Keyword.fetch!(opts, :cwd)
    pitch = Keyword.fetch!(opts, :pitch)

    roles = role_sequence(stack)
    ctx = %{cwd: cwd, pitch: pitch, artifacts: %{}}

    run_roles(roles, harness, ctx, opts)
  end

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
          advance_cycle_state_step("REVIEWED", ctx, opts)
          run_roles(rest, harness, ctx, opts)

        role == "context-curator" ->
          run_format_step(ctx.cwd, opts)
          advance_cycle_state_step("CURATED", ctx, opts)
          run_roles(rest, harness, ctx, opts)

        role == "committer" ->
          advance_cycle_state_step("COMMITTED", ctx, opts)
          run_roles(rest, harness, ctx, opts)

        true ->
          run_roles(rest, harness, ctx, opts)
      end
    end
  end

  defp developer_role?(role), do: String.starts_with?(role, "developer-")

  # After a developer role completes, run the gate. Clear → continue to the
  # reviewer/curator/committer tail. Non-clear → re-invoke the SAME
  # developer role (once, up to :max_gate_retries) with the gate's reason
  # folded into context; if still non-clear, {:error, reason}.
  defp run_gate_then_continue(dev_role, rest, harness, ctx, opts) do
    gate_fn = Keyword.get(opts, :gate_fn, &LoopGate.run_gate/2)
    max_retries = Keyword.get(opts, :max_gate_retries, 1)

    do_gate_loop(dev_role, rest, harness, ctx, opts, gate_fn, max_retries, 0)
  end

  defp do_gate_loop(dev_role, rest, harness, ctx, opts, gate_fn, max_retries, attempt) do
    case gate_fn.(ctx.cwd, opts) do
      {:clear, _gate_cmd} ->
        advance_cycle_state_step("GATED", ctx, opts)
        run_roles(rest, harness, ctx, opts)

      {:failed, _gate_cmd} ->
        if attempt < max_retries do
          with {:ok, result} <- invoke_with_retry(dev_role, harness, ctx, opts) do
            ctx = put_in(ctx, [:artifacts, dev_role], result)
            run_format_step(ctx.cwd, opts)
            do_gate_loop(dev_role, rest, harness, ctx, opts, gate_fn, max_retries, attempt + 1)
          end
        else
          {:error, "gate verdict=failed after #{attempt + 1} developer attempt(s)"}
        end

      {other, _gate_cmd} ->
        raise "OrchestrationLoop: unexpected gate verdict #{inspect(other)}"
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
  Invokes one role via `RoleResolver.resolve_role/2` → `codegen-call`,
  parses the `{result: {status, value, reason, ...}}` envelope, and
  branches on `status`.

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
    codegen_call_fn = Keyword.get(opts, :codegen_call_fn, &default_codegen_call/6)

    {system_prompt_path, model, effort, allowed_tools} = resolve_fn.(role, harness)

    prompt = build_prompt(role, ctx)

    envelope = codegen_call_fn.(harness, model, effort, system_prompt_path, allowed_tools, prompt)

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

  defp build_prompt(role, ctx) do
    reason = get_in(ctx, [:artifacts, :last_failure_reason])

    base = ctx[:pitch] || ""

    if reason do
      base <>
        "\n\nPrevious attempt at role #{role} failed with: #{reason}. Please address this and retry."
    else
      base
    end
  end

  @codegen_call_bin Path.expand("../../../codegen-call", __DIR__)
  @codegen_dir Path.expand("../../..", __DIR__)
  @claude_settings_path Path.expand(
                          "../../../harnesses/claude/claude-code-loop-settings.json",
                          __DIR__
                        )
  @pi_enforcement_ext_path Path.expand(
                             "../../../harnesses/pi/pi-extensions/enforcement",
                             __DIR__
                           )

  @doc """
  Resolves the B-bucket in-agent guard bundle flag for `harness`:

  - `"claude_code"` → `["--settings=@<claude-code-loop-settings.json>"]`
  - `"pi"` → `["--extension=@<enforcement extension dir>"]`

  The `"claude_code"` bundle is the MINIMAL per-role loop hook set (8 generic,
  signal:none, role:"*" denial hooks — see LOOP_BUNDLE_IDS in
  templates/generator/hook_registrations.py and context/core.md § Loop Settings
  Bundle), not the full installed settings.json. Every loop-invoked codegen-call
  runs WITHOUT role identity set, so AGENT_TYPE-gated role guards and
  orchestrator-* guards would either be dead weight or over-apply (e.g.
  orchestrator-no-source-edit would deny a loop `developer` editing lib/foo.ex).
  The legacy (non-loop) path is unaffected — it loads the full
  `~/.claude/settings.json` directly and does not call this function.

  RAISES (crash loud) if the resolved bundle path is absent — every role
  invocation MUST carry its guard bundle; a silently-unguarded run (e.g.
  committer without committer-single-commit-per-cycle, developer without
  llm-suite-guard) is exactly the failure mode this guards against.

  `opts`:
  - `:claude_settings_path` — override for testing (default: the committed
    `harnesses/claude/claude-code-loop-settings.json` minimal loop bundle)
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

  defp default_codegen_call(harness, model, effort, system_prompt_path, allowed_tools, prompt) do
    unless File.exists?(@codegen_call_bin) do
      raise "OrchestrationLoop: codegen-call not found at #{@codegen_call_bin}"
    end

    args =
      [
        "--harness=#{harness}",
        "--model=#{model}",
        "--effort=#{effort}",
        "--system-prompt=@#{system_prompt_path}"
      ] ++
        guard_bundle_flag!(harness) ++
        if(allowed_tools && allowed_tools != "",
          do: ["--allowed-tools=#{allowed_tools}"],
          else: []
        ) ++ [prompt]

    env = [
      {"CODEGEN_DIR", @codegen_dir},
      {"CODEGEN_BUILD_START_TS", Integer.to_string(System.system_time(:second))}
    ]

    {output, exit_code} =
      System.cmd(@codegen_call_bin, args, stderr_to_stdout: true, env: env)

    if exit_code != 0 do
      raise "OrchestrationLoop: codegen-call exited #{exit_code}:\n#{output}"
    end

    Jason.decode!(output)
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
end
