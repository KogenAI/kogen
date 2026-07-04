defmodule CodegenTestHarness.LoopGate do
  @moduledoc """
  Runs the gate as an explicit loop step: shells the existing bash
  contracts (`gate-select.sh` / `gate-result.sh`) rather than
  reimplementing gate-command selection or verdict derivation.

  Reuses `codegen/gate-pending/gate-result.json` verbatim — the schema
  the loop's downstream steps (and `codegen-build`'s own post-step read)
  already depend on stays byte-identical.
  """

  @type verdict :: :clear | :failed

  @gate_select_lib Path.expand(
                     "../../../harnesses/claude/hooks/lib/gate-select.sh",
                     __DIR__
                   )
  @gate_result_lib Path.expand(
                     "../../../harnesses/claude/hooks/lib/gate-result.sh",
                     __DIR__
                   )
  @render_check_js Path.expand(
                     "../../../harnesses/claude/hooks/lib/render-check.js",
                     __DIR__
                   )
  @codegen_root Path.expand("../../../..", Path.dirname(@render_check_js))

  @doc false
  # Test-only introspection: exposes the compile-time-derived codegen root
  # so tests can assert it resolves to the actual repo root (containing
  # node_modules/ and harnesses/) rather than re-deriving the same logic.
  @spec codegen_root() :: String.t()
  def codegen_root, do: @codegen_root

  @doc """
  Decides the gate command for `project_dir` (optionally scoped by
  `step_log`, the active session-log path used for the planner's
  `**Gate**:` line) via `gate-select.sh`'s `gate_select_decide`.

  Returns `{gate_command, mode, timeout_secs}`. Raises if `gate-select.sh`
  is missing or the decision cannot be parsed.
  """
  @spec decide_gate(String.t(), String.t() | nil) :: {String.t(), String.t(), non_neg_integer()}
  def decide_gate(project_dir, step_log \\ nil) do
    unless File.exists?(@gate_select_lib) do
      raise "LoopGate: gate-select.sh not found at #{@gate_select_lib}"
    end

    args = if step_log, do: [project_dir, step_log], else: [project_dir]
    arg_str = Enum.map_join(args, " ", &shell_quote/1)

    script = "source #{shell_quote(@gate_select_lib)} && gate_select_decide #{arg_str}"

    {output, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)

    if String.starts_with?(String.trim(output), "__GATE_PARSE_ERROR__:") do
      raise "LoopGate: gate_select_decide returned a parse error — #{String.trim(output)}"
    end

    gate = capture_line(output, ~r/^gate=(.*)$/m)
    mode = capture_line(output, ~r/^mode=(.*)$/m)
    timeout = capture_line(output, ~r/^timeout=(.*)$/m)

    if is_nil(gate) or is_nil(mode) or is_nil(timeout) do
      raise "LoopGate: could not parse gate_select_decide output:\n#{output}"
    end

    {gate, mode, String.to_integer(timeout)}
  end

  @doc """
  Runs the gate for `project_dir`: decides the gate command, executes it
  in `project_dir`, writes `gate-result.json` via `write_gate_result`, and
  returns `{verdict, gate_command}`.

  `opts`:
  - `:stack` — `"phoenix"` | `"static"`. For `"static"`, a render check
    (headless-Chromium DOM/style/JS-error verification via `render-check.js`)
    runs after a clear gate command exit, mirroring the function of the
    deleted `static-site-build-check.sh` SubagentStop hook (dead under the
    loop — no SubagentStop fires for a main-agent `codegen-call` session).
  - `:step_log` — session-log path forwarded to `decide_gate/2`
  - `:session_id` — recorded in `gate-result.json` (default `""`)
  - `:run_fn` — test seam: `(gate_command, project_dir -> {output, exit_code})`,
    defaults to a real `System.cmd("bash", ["-c", gate_command], cd: project_dir)`
    invocation.
  - `:render_check_fn` — test seam: `(project_dir -> {verdict_line, exit_code})`,
    defaults to a real `render-check.js` invocation against `project_dir/public`.
  - `:preflight_fn` — test seam: `(project_dir -> :ok)`, defaults to
    `&static_render_deps_preflight!/1`. Runs BEFORE the gate command, only
    when `:stack` is `"static"`. RAISES (crash loud, infra abort — not a
    gate verdict) naming the first missing render-check dependency
    (node, render-check.js, chromium).

  Never raises on a failing gate command or a failing render check — a
  `:failed` verdict is a legitimate return value, not an error. Missing
  render-check *dependencies* (as opposed to a failing check) are an infra
  abort and DO raise, via `:preflight_fn`.
  """
  @spec run_gate(String.t(), keyword()) :: {verdict(), String.t()}
  def run_gate(project_dir, opts \\ []) do
    stack = Keyword.get(opts, :stack)
    step_log = Keyword.get(opts, :step_log)
    session_id = Keyword.get(opts, :session_id, "")
    run_fn = Keyword.get(opts, :run_fn, &default_run_fn/2)
    preflight_fn = Keyword.get(opts, :preflight_fn, &static_render_deps_preflight!/1)

    if stack == "static", do: preflight_fn.(project_dir)

    {gate, mode, _timeout} = decide_gate(project_dir, step_log)

    # gate-select.sh's no-config fallback is stack-blind: mix.exs → "make ci",
    # everything else → "make test". The loop's static sequence has no planner
    # to write a `**Gate**:` line, so a static project falls back to "make test"
    # (absent in a static app → permanent gate failure). Force the static gate
    # (build + prettier) here. Loop-local — the shared gate-select stays
    # untouched (codegen's own repo gate is legitimately "make test").
    gate = stack_default_gate(stack, gate)

    started = now_iso8601()
    {output, exit_code} = run_fn.(gate, project_dir)

    {render_verdict, output} =
      if stack == "static" and exit_code == 0 do
        run_static_render_check(project_dir, output, opts)
      else
        {"", output}
      end

    ended = now_iso8601()

    log_path = write_gate_log!(project_dir, output)

    unless File.exists?(@gate_result_lib) do
      raise "LoopGate: gate-result.sh not found at #{@gate_result_lib}"
    end

    write_script = """
    source #{shell_quote(@gate_result_lib)} && write_gate_result \
      #{shell_quote(gate)} #{shell_quote(mode)} "" 0 \
      true #{exit_code} 1 1 #{shell_quote(render_verdict)} "" \
      #{shell_quote(started)} #{shell_quote(ended)} \
      #{shell_quote(session_id)} #{shell_quote(log_path)} #{shell_quote(project_dir)}
    """

    {_write_out, 0} = System.cmd("bash", ["-c", write_script], stderr_to_stdout: true)

    {read_verdict(project_dir), gate}
  end

  # Stack-aware default gate when gate-select.sh fell back to the stack-blind
  # "make test" default. A static project's gate is "make ci" (build+prettier).
  defp stack_default_gate("static", "make test"), do: "make ci"
  defp stack_default_gate(_stack, gate), do: gate

  # Runs the static-stack render check (headless Chromium via render-check.js)
  # against `<project_dir>/public`. Returns `{render_verdict_line, combined_output}`.
  # No output dir → skipped (render_verdict stays "", gate-result.sh treats
  # "" the same as PASS — see _derive_verdict table). Never raises: a
  # crashed/missing render-check is INCONCLUSIVE, not a hard failure — it
  # must never silently masquerade as PASS, but it also must not take down
  # the whole gate on an infra hiccup (chromium missing, etc.).
  defp run_static_render_check(project_dir, gate_output, opts) do
    render_check_fn = Keyword.get(opts, :render_check_fn, &default_render_check_fn/1)
    out_dir = Path.join(project_dir, "public")

    if File.dir?(out_dir) do
      {verdict_line, _exit} = render_check_fn.(project_dir)
      verdict = extract_render_verdict(verdict_line)
      {verdict, gate_output <> "\n" <> verdict_line}
    else
      {"", gate_output}
    end
  end

  defp extract_render_verdict(output) do
    case Regex.run(~r/^RENDER_VERDICT=(.*)$/m, output) do
      [_, verdict] -> String.trim(verdict)
      nil -> "INCONCLUSIVE:render-check-no-verdict"
    end
  end

  defp default_render_check_fn(project_dir) do
    out_dir = Path.join(project_dir, "public")

    unless File.exists?(@render_check_js) do
      {"RENDER_VERDICT=INCONCLUSIVE:render-check-cmd-missing", 0}
    else
      case System.find_executable("node") do
        nil ->
          {"RENDER_VERDICT=INCONCLUSIVE:render-check-cmd-missing", 0}

        node ->
          {output, _exit} =
            System.cmd(
              node,
              [@render_check_js, "--mode", "static", "--timeout", "30000", out_dir],
              stderr_to_stdout: true
            )

          {output, 0}
      end
    end
  end

  @doc """
  Reads the verdict field from `<project_dir>/codegen/gate-pending/gate-result.json`
  via `gate_result_verdict`. Raises if the field is absent or unrecognized —
  the loop must never silently treat a missing/malformed verdict as clear.

  The legacy bash contract's `"inconclusive"` value collapses fail-closed to
  `:failed` here — the loop's verdict is binary (`:clear | :failed`); an
  inconclusive render-check result must never let a cycle proceed as if it
  were clear.
  """
  @spec read_verdict(String.t()) :: verdict()
  def read_verdict(project_dir) do
    unless File.exists?(@gate_result_lib) do
      raise "LoopGate: gate-result.sh not found at #{@gate_result_lib}"
    end

    script =
      "source #{shell_quote(@gate_result_lib)} && gate_result_verdict #{shell_quote(project_dir)}"

    {output, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)

    case String.trim(output) do
      "clear" -> :clear
      "failed" -> :failed
      "inconclusive" -> :failed
      other -> raise "LoopGate: unrecognized/missing verdict #{inspect(other)} for #{project_dir}"
    end
  end

  # Static-stack render-check dependency preflight. Runs BEFORE the gate
  # command when `:stack` is `"static"`. RAISES (crash loud) naming the
  # FIRST missing dependency — this is an infra abort, not a gate verdict:
  # a missing dep is a box-provisioning problem, not something a developer
  # re-run can fix.
  #
  # Mirrors render-check.js's exact playwright/chromium resolution
  # (harnesses/claude/hooks/lib/render-check.js:119-135) so the preflight
  # can never false-abort (dep present but preflight looked in the wrong
  # place) or false-pass (preflight happy but the real check still fails).
  @spec static_render_deps_preflight!(String.t()) :: :ok
  defp static_render_deps_preflight!(_project_dir) do
    unless System.find_executable("node") do
      raise "LoopGate: render-check dependency missing — node not on PATH"
    end

    unless File.exists?(@render_check_js) do
      raise "LoopGate: render-check.js not found at #{@render_check_js}"
    end

    probe_script = """
    const path = require("path");
    const fs = require("fs");
    const candidates = [];
    const codegenDir = process.env["CODEGEN_DIR"];
    if (codegenDir) {
      candidates.push(path.join(codegenDir, "node_modules", "playwright"));
    }
    candidates.push(path.join(#{inspect(@codegen_root)}, "node_modules", "playwright"));
    candidates.push("playwright");
    let chromium;
    let resolved = false;
    for (const candidate of candidates) {
      try {
        ({ chromium } = require(candidate));
        resolved = true;
        break;
      } catch (_e) {
        // try next candidate
      }
    }
    if (!resolved) {
      process.exit(1);
    }
    if (!fs.existsSync(chromium.executablePath())) {
      process.exit(1);
    }
    process.exit(0);
    """

    {_output, exit_code} = System.cmd("node", ["-e", probe_script], stderr_to_stdout: true)

    unless exit_code == 0 do
      raise "LoopGate: chromium binary not found — run: npx playwright install chromium"
    end

    :ok
  end

  defp default_run_fn(gate_command, project_dir) do
    System.cmd("bash", ["-c", gate_command], cd: project_dir, stderr_to_stdout: true)
  end

  defp write_gate_log!(project_dir, output) do
    dir = Path.join(project_dir, "codegen/gate-pending")
    File.mkdir_p!(dir)
    log_path = Path.join(dir, "gate-run.log")
    File.write!(log_path, output)
    log_path
  end

  defp capture_line(output, regex) do
    case Regex.run(regex, output) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"
end
