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
  @codegen_log_bin Path.expand("../../../codegen-log", __DIR__)
  @codegen_dir Path.expand("../../..", __DIR__)

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

    if String.starts_with?(String.trim(output), "__GATE_UNRESOLVED__:") do
      raise "LoopGate: gate_select_decide could not resolve a gate — #{String.trim(output)}"
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
  Extracts the concatenated planner role body text from a JSONL cycle log,
  via `gate-select.sh`'s `planner_body_from_log` — the SAME decoder
  `decide_gate/2` already shells for the `**Gate**:`/`gate-json` scan, reused
  here rather than reimplemented. Returns `""` when `log_file` is nil,
  missing, unreadable, or carries no planner role event (never raises —
  the caller decides what an empty body means).
  """
  @spec planner_body(String.t() | nil) :: String.t()
  def planner_body(nil), do: ""

  def planner_body(log_file) when is_binary(log_file) do
    unless File.exists?(@gate_select_lib) do
      raise "LoopGate: gate-select.sh not found at #{@gate_select_lib}"
    end

    script =
      "source #{shell_quote(@gate_select_lib)} && planner_body_from_log #{shell_quote(log_file)}"

    {output, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)

    output
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
    The gate command itself comes solely from `decide_gate/2` (planner
    `**Gate**:` line, or per-app `.claude/gate-config.sh` GATE_COMMAND) —
    there is no stack-derived default gate.
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
  - `:cycle_log` — path to the active cycle-log JSONL file (the loop's
    `Process.get(@log_path_key)`, threaded in via `gate_opts/1`). When
    present, the derived verdict marker (`"ALL CLEAR ✅"` / `"FAILED ❌"` /
    `"INCONCLUSIVE ⚠️"`) is recorded into the cycle log as a `{"ev":"gate"}`
    event via `codegen-log verdict`, in addition to the existing
    `gate-result.json` / `gate-verdicts.jsonl` writes. `nil` (no log
    initialized, e.g. most unit tests) → no-op, silently.
  - `:log_verdict_fn` — test seam: `(cycle_log, gate_command, mode, marker -> :ok)`,
    defaults to `&default_log_verdict/4`.

  Never raises on a failing gate command or a failing render check — a
  `:failed` verdict is a legitimate return value, not an error. Missing
  render-check *dependencies* (as opposed to a failing check) are an infra
  abort and DO raise, via `:preflight_fn`.

  A failed `codegen-log verdict` write (missing binary, non-zero exit) is
  fail-loud-non-blocking: it prints to stderr and the gate verdict returned
  to the caller is unaffected — this is an observability write, never a
  reason to flip a green gate red or a red gate green.

  `gate-result.json` also carries `graded_tree_sha` — a real git tree
  object hashing HEAD plus every working-tree change at gate time (see
  `graded_tree_sha/1`), computed via a temporary index so the repo's own
  index is never touched. This binds the verdict to the exact content it
  graded; `base_sha` alone only pins HEAD, which stays unchanged across a
  post-gate revert. `""` when `project_dir` is not a git repo (fail-open,
  same sentinel as `base_sha`).
  """
  @spec run_gate(String.t(), keyword()) :: {verdict(), String.t()}
  def run_gate(project_dir, opts \\ []) do
    stack = Keyword.get(opts, :stack)
    step_log = Keyword.get(opts, :step_log)
    session_id = Keyword.get(opts, :session_id, "")
    run_fn = Keyword.get(opts, :run_fn, &default_run_fn/2)
    preflight_fn = Keyword.get(opts, :preflight_fn, &static_render_deps_preflight!/1)
    cycle_log = Keyword.get(opts, :cycle_log)
    log_verdict_fn = Keyword.get(opts, :log_verdict_fn, &default_log_verdict/4)

    if stack == "static", do: preflight_fn.(project_dir)

    {gate, mode, _timeout} = decide_gate(project_dir, step_log)

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

    base_sha = gate_base_sha(project_dir)
    diff_files_count = gate_diff_files_count(project_dir)
    tree_sha = graded_tree_sha(project_dir)

    write_script = """
    source #{shell_quote(@gate_result_lib)} && write_gate_result \
      #{shell_quote(gate)} #{shell_quote(mode)} #{shell_quote(base_sha)} #{diff_files_count} \
      true #{exit_code} 1 1 #{shell_quote(render_verdict)} "" \
      #{shell_quote(started)} #{shell_quote(ended)} \
      #{shell_quote(session_id)} #{shell_quote(log_path)} #{shell_quote(project_dir)} \
      "" #{shell_quote(tree_sha)}
    """

    {_write_out, 0} = System.cmd("bash", ["-c", write_script], stderr_to_stdout: true)

    marker = gate_verdict_marker(project_dir)
    log_verdict_fn.(cycle_log, gate, mode, marker)

    {read_verdict(project_dir), gate}
  end

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

  @doc """
  Reads the `graded_tree_sha` field the last `run_gate/2` call stamped into
  `<project_dir>/codegen/gate-pending/gate-result.json`. Returns `""` when
  the file/field is absent (legacy record, or a gate that hasn't run).
  """
  @spec gate_result_graded_tree_sha(String.t()) :: String.t()
  def gate_result_graded_tree_sha(project_dir) do
    unless File.exists?(@gate_result_lib) do
      raise "LoopGate: gate-result.sh not found at #{@gate_result_lib}"
    end

    script =
      "source #{shell_quote(@gate_result_lib)} && gate_result_graded_tree_sha #{shell_quote(project_dir)}"

    {output, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    String.trim(output)
  end

  @doc """
  Recomputes the CURRENT working-tree content-hash for `project_dir` — the
  same computation `run_gate/2` stamps at gate time (see `graded_tree_sha/1`
  private helper), exposed publicly so the loop's pre-commit re-check
  (`verify_gate_graded_this_tree/2`) can compare "what the gate graded" vs.
  "what the tree looks like right now, immediately before the committer
  runs" without re-running the whole gate.
  """
  @spec graded_tree_sha_now(String.t()) :: String.t()
  def graded_tree_sha_now(project_dir), do: graded_tree_sha(project_dir)

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

  # Short HEAD of `project_dir` at GATE time (pre-commit — the loop gates
  # before the committer in role order). "" when project_dir is not a git
  # repo — fail-closed sentinel: the drain's freshness check treats "" as
  # never-fresh, and LoopGate's own tests run in a bare non-git tmp dir.
  @spec gate_base_sha(String.t()) :: String.t()
  defp gate_base_sha(project_dir) do
    case System.cmd("git", ["-C", project_dir, "rev-parse", "--short", "HEAD"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      {_out, _code} -> ""
    end
  end

  # Count of changed (tracked + untracked) files in `project_dir` at gate
  # time. 0 when project_dir is not a git repo (fail-open — observability
  # only, nothing branches on this value today).
  @spec gate_diff_files_count(String.t()) :: non_neg_integer()
  defp gate_diff_files_count(project_dir) do
    case System.cmd("git", ["-C", project_dir, "status", "--porcelain"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> length()
      {_out, _code} -> 0
    end
  end

  # Content-hash of the working tree at gate time: HEAD's tree with every
  # working-tree change (tracked modifications, deletions, and untracked
  # files, .gitignore-respecting) overlaid — via a TEMPORARY index, never
  # the repo's real index. This is a real git tree object (comparable
  # directly to `git rev-parse HEAD^{tree}` after a commit), NOT
  # `tree_signature/1`'s shasum-of-shasums digest (different value space —
  # cannot be compared post-commit, which is the entire point of this
  # binding).
  #
  # `git update-index -q --refresh` FIRST is required, not optional — the
  # racy-stat cache otherwise reports zero changes and the tree silently
  # collapses to `HEAD^{tree}`, turning this into a no-op that always
  # matches (a green-looking false pass). Confirmed by direct probe: the
  # sequence without --refresh returns HEAD^{tree} even on a dirty tree.
  #
  # "" when project_dir is not a git repo or HEAD is unborn — the same
  # fail-open sentinel gate_base_sha/1 already uses. Only mocked tests and
  # bare tmp dirs land there; a real loop run always operates inside the
  # scaffolded project's git repo.
  @spec graded_tree_sha(String.t()) :: String.t()
  defp graded_tree_sha(project_dir) do
    case System.cmd("git", ["-C", project_dir, "rev-parse", "--verify", "-q", "HEAD"],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> compute_graded_tree_sha(project_dir)
      {_out, _code} -> ""
    end
  end

  defp compute_graded_tree_sha(project_dir) do
    git_dir =
      case System.cmd("git", ["-C", project_dir, "rev-parse", "--git-dir"],
             stderr_to_stdout: true
           ) do
        {out, 0} -> String.trim(out)
        {_out, _code} -> nil
      end

    if is_nil(git_dir) do
      ""
    else
      abs_git_dir = Path.expand(git_dir, project_dir)

      tmp_index =
        Path.join(abs_git_dir, "codegen-graded-tree-index-#{:erlang.unique_integer([:positive])}")

      script = """
      set -e
      cd #{shell_quote(project_dir)}
      git update-index -q --refresh || true
      rm -f #{shell_quote(tmp_index)}
      GIT_INDEX_FILE=#{shell_quote(tmp_index)} git read-tree HEAD
      git ls-files -m -d -o --exclude-standard -z | \
        GIT_INDEX_FILE=#{shell_quote(tmp_index)} git update-index --add --remove -z --stdin
      GIT_INDEX_FILE=#{shell_quote(tmp_index)} git write-tree
      """

      result =
        case System.cmd("bash", ["-c", script], stderr_to_stdout: true) do
          {out, 0} -> out |> String.trim() |> String.split("\n") |> List.last() |> String.trim()
          {_out, _code} -> ""
        end

      File.rm(tmp_index)
      result
    end
  end

  # Reads the "verdict_marker" field back out of gate-result.json — the
  # byte-exact string ("ALL CLEAR ✅" / "FAILED ❌" / "INCONCLUSIVE ⚠️")
  # codegen-log's `verdict` subcommand classifies on. read_verdict/1's atom
  # cannot carry this: it collapses "inconclusive" to :failed, so the atom
  # would silently destroy the distinction this event exists to preserve.
  # "" (absent/malformed file) → default_log_verdict/4 no-ops loudly rather
  # than writing a bogus event.
  @spec gate_verdict_marker(String.t()) :: String.t()
  defp gate_verdict_marker(project_dir) do
    path = Path.join(project_dir, "codegen/gate-pending/gate-result.json")

    with {:ok, contents} <- File.read(path),
         {:ok, %{"verdict_marker" => marker}} <- Jason.decode(contents),
         true <- is_binary(marker) do
      marker
    else
      _ -> ""
    end
  end

  # Default :log_verdict_fn — shells `codegen-log verdict` against
  # `cycle_log` via CODEGEN_LOG_PATH. nil cycle_log (no log initialized,
  # e.g. most unit tests) or an empty marker (gate_verdict_marker/1 could
  # not read one) → silent no-op, never an error. A non-zero codegen-log
  # exit is fail-loud-non-blocking: this is an observability write, and
  # must never flip the gate's own verdict.
  @spec default_log_verdict(String.t() | nil, String.t(), String.t(), String.t()) :: :ok
  defp default_log_verdict(nil, _gate, _mode, _marker), do: :ok
  defp default_log_verdict(_cycle_log, _gate, _mode, ""), do: :ok

  defp default_log_verdict(cycle_log, gate, mode, marker) do
    unless File.exists?(@codegen_log_bin) do
      IO.puts(
        :stderr,
        "LoopGate: codegen-log not found at #{@codegen_log_bin} — verdict not logged"
      )

      :ok
    else
      {output, exit_code} =
        System.cmd(
          @codegen_log_bin,
          ["verdict", "--gate", gate, "--mode", mode, "--result", marker],
          stderr_to_stdout: true,
          env: [{"CODEGEN_DIR", @codegen_dir}, {"CODEGEN_LOG_PATH", cycle_log}]
        )

      if exit_code != 0 do
        IO.puts(:stderr, "LoopGate: codegen-log verdict failed (#{exit_code}): #{output}")
      end

      :ok
    end
  end

  defp default_run_fn(gate_command, project_dir) do
    scrub =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "CODEGEN_BUILD_"))
      |> Enum.map(&{&1, nil})

    System.cmd("bash", ["-c", gate_command],
      cd: project_dir,
      stderr_to_stdout: true,
      env: scrub
    )
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
