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
  @type fault_class :: :code | :infra
  @type owner_class :: {:owner, String.t()} | :infra

  defmodule CanaryError do
    @moduledoc """
    Raised by `run_gate/2` when the gate's own no-op-gate detector
    (`gate-result.sh`'s `_derive_verdict`) fails to prove it can still
    return `failed` on a known-bad input (an empty gate log against the
    real gate command's `evidence_fn`-derived `expected_segments`).

    A gate that cannot fail is not a gate — see
    `rearm-the-verifier-is-not-a-passenger` pitch. No verdict is issued
    when this raises: `run_gate/2` unlinks any stale `gate-result.json`
    BEFORE the canary check runs, so a raise here always leaves the
    verdict absent (fail-closed), never a leftover prior `clear`.
    """
    defexception [:message]
  end

  # Text signatures a FAILED gate/scan can carry that name a
  # box-provisioning fault rather than a code defect — matched against the
  # gate-run.log / scan-violation text a caller passes to `classify_failure/1`.
  # Conservative and additive: an unrecognized failure is ALWAYS `:code`
  # (see `classify_failure/1` doc) so this list can only ever EXCUSE a
  # failure it explicitly recognizes, never silently excuse a real defect.
  #
  # - Postgrex/ecto errors naming pre-existing DB state the diff did not
  #   create (relation/role already-exists or does-not-exist against a
  #   migration the diff never touched) — the 20260713 `bouncer-prompt-
  #   rule-collisions` incident: `mix ecto.rollback` poisoned by
  #   pre-existing DB state no diff could turn green.
  # - `gate-result.sh`'s own environmental classification vocabulary
  #   (`seed-missing`, `pool-exhaustion`) — already shipped but previously
  #   unreachable from the loop (classification was hardcoded to `""`).
  @infra_signatures [
    ~r/\*\* \(Postgrex\.Error\)/,
    ~r/relation "[^"]+" already exists/,
    ~r/role "[^"]+" does not exist/,
    ~r/database "[^"]+" does not exist/,
    ~r/seed-missing/,
    ~r/pool-exhaustion/
  ]

  @doc """
  Classifies a FAILED check's raw text (gate-run.log content, or a scan's
  violation string) as `:code` (a developer edit can plausibly fix it) or
  `:infra` (a box-provisioning fault no edit can fix — abort, don't
  rework).

  Default is ALWAYS `:code` for text matching none of `@infra_signatures`
  — an unrecognized failure stays the developer's, so this classifier can
  never silently excuse a real defect (mirrors the pitch's explicit
  "default is :code" requirement).
  """
  @spec classify_failure(String.t()) :: fault_class()
  def classify_failure(text) when is_binary(text) do
    if Enum.any?(@infra_signatures, &Regex.match?(&1, text)) do
      :infra
    else
      :code
    end
  end

  # Load-failure phrasing distinct from a genuine undefined-function typo:
  # `mix test` against a stale `_build` emits `** (UndefinedFunctionError)
  # function Foo.bar/1 is undefined (module Foo is not available)` for
  # EVERY call into an unloaded module — a typo'd call to a real,
  # loaded module instead says "is undefined or private" with no
  # "module ... is not available" clause. Matching only the
  # module-unavailable clause, plus a >=2-distinct-module threshold below,
  # keeps a single genuinely-deleted module routed to `:code` as before.
  @stale_build_signature ~r/module ([A-Z][\w.]*) is not available/

  @doc """
  Detects a stale `_build` gate failure: the gate log names two or more
  DISTINCT modules as "not available" — the whole app failed to load
  against unrecompiled artifacts, not a single missing/renamed module.

  A single unavailable module stays `false` here (routes to the ordinary
  `:code` classification) — deleting/renaming one module is a plausible
  real code defect, not a stale build.
  """
  @spec stale_build?(String.t()) :: boolean()
  def stale_build?(text) when is_binary(text) do
    @stale_build_signature
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> length() >= 2
  end

  @doc """
  Generalizes `static_render_deps_preflight!/1`'s raise into a
  stack-agnostic infra-abort seam: raises `CodegenTestHarness.InfraAbort`
  naming `reason` — a fault classified `:infra` by `classify_failure/1`.
  Never returns.
  """
  @spec infra_abort!(String.t(), String.t()) :: no_return()
  def infra_abort!(check_name, reason) do
    raise CodegenTestHarness.InfraAbort, "#{check_name}: #{reason}"
  end

  # Floor applied to a gate's declared timeout when `gate_timeout_for`
  # returns `0` ("no budget declared" — the truthful fallthrough for
  # `make test` and any unrecognized command; see `gate-select.sh`'s own
  # contract comment and its green `gate-select_test.sh:46` pin). `0` is
  # NEVER enforced literally as a deadline — that would make every build
  # carrying an unrecognized/undeclared gate command instantly
  # INCONCLUSIVE, the universal fake-RED twin of the fake-GREEN this module
  # exists to close. Reuses the existing `make ci` budget (900s) rather than
  # minting a new constant: generous enough that no honest short gate hits
  # it, finite enough that a genuine hang still surfaces.
  @default_short_gate_timeout 900

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
  Decides the gate command for `project_dir` via `gate-select.sh`'s
  `gate_select_decide`, which resolves it solely from the project's own
  `.claude/gate-config.sh` (`GATE_COMMAND`, plus the optional `GATE_MODE` /
  `GATE_TIMEOUT` overrides). No cycle carries a per-cycle gate selection any
  more, so there is nothing session-scoped left to pass.

  Returns `{gate_command, mode, timeout_secs}`. Raises if `gate-select.sh`
  is missing or the decision cannot be parsed.
  """
  @spec decide_gate(String.t()) :: {String.t(), String.t(), non_neg_integer()}
  def decide_gate(project_dir) do
    unless File.exists?(@gate_select_lib) do
      raise "LoopGate: gate-select.sh not found at #{@gate_select_lib}"
    end

    script =
      "source #{shell_quote(@gate_select_lib)} && gate_select_decide #{shell_quote(project_dir)}"

    {output, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)

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
  Mechanical predicate for "does this cycle have anything for
  context-curator to curate?", read from the cycle's own JSONL via
  `gate-select.sh`'s `curator_learning_signal_from_log`. Returns one of:

  - `:learned` — >=1 `{"ev":"learned"}` event exists anywhere in the log.
  - `:no_learning` — zero `ev:learned` events AND >=1 `{"ev":"no_learning"}`
    event (every role that ran honestly declared nothing durable learned).
  - `:absent` — neither event kind present (missing/unreadable log,
    truncated cycle, or a legacy log predating the `ev:no_learning`
    contract). Fail-SAFE: callers MUST treat `:absent` the same as
    `:learned` (spawn the curator) — a missing signal is never read as
    permission to skip.

  Returns `:absent` when `log_file` is `nil`. Never raises.
  """
  @spec curator_learning_signal(String.t() | nil) :: :learned | :no_learning | :absent
  def curator_learning_signal(nil), do: :absent

  def curator_learning_signal(log_file) when is_binary(log_file) do
    unless File.exists?(@gate_select_lib) do
      raise "LoopGate: gate-select.sh not found at #{@gate_select_lib}"
    end

    script =
      "source #{shell_quote(@gate_select_lib)} && curator_learning_signal_from_log #{shell_quote(log_file)}"

    {output, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)

    case String.trim(output) do
      "learned" -> :learned
      "no_learning" -> :no_learning
      _ -> :absent
    end
  end

  @doc """
  Sibling of `curator_learning_signal/1`: returns the cycle's own
  `{"ev":"learned"}` events THEMSELVES (one `"role: text"` string per
  event), not just the three-valued spawn signal — the material
  `context-curator.md:3` names as the curator's ONLY routine input (pitch
  "hand each role the material its job needs", move 3). Shells
  `gate-select.sh`'s sibling `curator_learnings_from_log`.

  Returns one of three DISTINCT outcomes — never collapsed to a single
  silent case, per the pitch's D12 (a swallowed read error must not read
  identically to "nothing was learned"):

  - `{:ok, events}` — log exists and was read; `events` is a (possibly
    empty) list of `"role: text"` strings. An empty list is legitimate —
    a cycle can honestly produce no `ev:learned` events.
  - `{:error, :absent}` — `log_file` is `nil` (no log initialized this
    cycle, e.g. most unit tests).
  - `{:error, :unreadable}` — `log_file` is set but does not exist / is
    not a regular file on disk.

  Never raises.
  """
  @spec curator_learnings(String.t() | nil) ::
          {:ok, [String.t()]} | {:error, :absent | :unreadable}
  def curator_learnings(nil), do: {:error, :absent}

  def curator_learnings(log_file) when is_binary(log_file) do
    unless File.exists?(@gate_select_lib) do
      raise "LoopGate: gate-select.sh not found at #{@gate_select_lib}"
    end

    script =
      "source #{shell_quote(@gate_select_lib)} && curator_learnings_from_log #{shell_quote(log_file)}"

    case System.cmd("bash", ["-c", script], stderr_to_stdout: true) do
      {output, 0} ->
        events = output |> String.split("\n", trim: true)
        {:ok, events}

      {_output, _nonzero} ->
        {:error, :unreadable}
    end
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
    The gate command itself comes solely from `decide_gate/1` (the per-app
    `.claude/gate-config.sh` GATE_COMMAND) — there is no stack-derived
    default gate.
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
  - `:log_verdict_fn` — test seam: `(cycle_log, gate_command, mode, marker, detail -> :ok)`,
    defaults to `&default_log_verdict/5`. `detail` is the located witness
    (`file:line — <verbatim cause>`) on a non-empty witness, else a named
    sentinel (`"no parseable failure location in <N>-byte gate log"` /
    `"gate produced no output"`) — see `witness_detail/3`. Threaded onward
    into `codegen-log verdict --detail` so the durable cycle log carries the
    same cause the developer's rework prompt already sees, instead of the
    `""` it silently dropped before.
  - `:evidence_fn` — test seam: `(gate_command, gate_output -> {execution_evidence, expected_segments}
    :: {non_neg_integer(), non_neg_integer()})`, defaults to `&default_evidence/2`.
    Feeds `gate-result.sh`'s no-op-gate detector (`execution_evidence <
    expected_segments → failed`) real, counted operands instead of the
    historical hardcoded `1 1` — a gate command that exits 0 having produced
    no evidence of running now correctly yields `FAILED ❌`. `expected_segments`
    is the number of `&&`-chained sub-commands in `gate_command` (a single
    command → 1); `execution_evidence` is the count of recognized runner
    summary footers in `gate_output` (ExUnit `N tests, N failures`, the hook
    runner's `N passed, N failed`), falling back to 1 when the output is
    non-empty but carries no recognized footer (many gates, e.g. `npm run
    build`, print no test-count footer at all — only a truly EMPTY gate log
    must count as zero evidence).
  - `:canary_fn` — test seam: `(gate_command, evidence_fn -> verdict() |
    :inconclusive)`, defaults to `&default_canary/2`. Runs BEFORE the real
    gate command: asks `_derive_verdict` to grade a known-bad input (an
    empty gate log against the real command's own `expected_segments`) and
    requires `:failed` back. Anything else means the no-op-gate detector
    cannot fail — `run_gate/2` raises `CodegenTestHarness.LoopGate.CanaryError`
    rather than certify any verdict from a gate proven unable to return
    `FAILED ❌`. Any stale `gate-result.json` is unlinked BEFORE this check
    runs, so the raise always leaves the verdict absent, never a leftover
    prior `clear` (see `CanaryError` moduledoc).

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
    session_id = Keyword.get(opts, :session_id, "")
    # Which BUILD this gate run belongs to. `session_id` above holds a ROLE
    # name, so it cannot separate two builds — every verdict in
    # gate-verdicts.jsonl looked alike and gate time could not be summed per
    # build. The loop is the only holder of the cycle id (it threads it in via
    # `gate_opts/2`); "" for any caller outside a loop, which is every
    # downstream app.
    cycle_id = Keyword.get(opts, :cycle_id, "")
    run_fn = Keyword.get(opts, :run_fn, &default_run_fn/2)
    preflight_fn = Keyword.get(opts, :preflight_fn, &static_render_deps_preflight!/1)
    cycle_log = Keyword.get(opts, :cycle_log)
    log_verdict_fn = Keyword.get(opts, :log_verdict_fn, &default_log_verdict/5)
    evidence_fn = Keyword.get(opts, :evidence_fn, &default_evidence/2)
    canary_fn = Keyword.get(opts, :canary_fn, &default_canary/2)
    isolated_rerun_fn = Keyword.get(opts, :isolated_rerun_fn, &default_isolated_rerun_fn/2)

    # Unlink any stale gate-result.json FIRST — before anything else in this
    # function can raise (canary, preflight, a crash). Every abort path
    # (canary failure, static_render_deps_preflight!'s raise, an unexpected
    # exception) must leave the verdict ABSENT, never a leftover prior
    # `clear` sitting on disk for `codegen-commit` to read.
    # `read_verdict/1` already raises loud on an absent file — "absent"
    # already denies; this just makes every raise fail-closed instead of
    # fail-open on a stale file (ledger #21).
    File.rm(gate_result_path(project_dir))

    if stack == "static", do: preflight_fn.(project_dir)

    {gate, mode, timeout} = decide_gate(project_dir)

    canary_verdict = canary_fn.(gate, evidence_fn)

    unless canary_verdict == :failed do
      raise CanaryError,
            "LoopGate: the gate cannot fail — refusing to certify " <>
              "(canary on #{inspect(gate)} returned #{inspect(canary_verdict)} " <>
              "instead of :failed against an empty gate log)"
    end

    started = now_iso8601()
    {output, exit_code} = run_with_deadline(run_fn, gate, project_dir, timeout)

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

    # Classify a non-zero exit's raw output against the infra-fault
    # signatures `classify_failure/1` knows — feeds `gate-result.sh`'s
    # pre-existing `seed-missing|pool-exhaustion` environmental-
    # classification branch (previously unreachable: this arg was
    # hardcoded to `""`). Only ever narrows `gate-result.json`'s own
    # `classification`/`verdict_marker` fields for observability —
    # `run_gate/2`'s RETURNED verdict stays the binary `:clear | :failed`
    # contract (ledger #6): callers that need the infra/code distinction
    # read it back via `classify_failure/1` on the gate log themselves
    # (see `OrchestrationLoop.do_gate_loop/9`), not from this return value.
    infra_tag = if exit_code != 0, do: infra_classification_tag(output), else: ""

    # Fault 1 / Move 2a — load-starvation classification: when the gate's
    # ONLY failing test is attributable to exactly one ExUnit test file (a
    # single-file classification, see `single_failing_test_file/1`), and no
    # infra signature already classified the failure, re-run THAT ONE FILE
    # ALONE, once — never a retry loop, never the whole suite. If the
    # isolated run passes, the failure is a load/order-sensitivity signature
    # (the `born_dead_detector_test.exs` incident: 2/2 fails inside the full
    # suite at --max-cases 24, 8/8 passes alone), not a code defect — tag it
    # `flake-isolated:<file>` so `gate-result.sh`'s `_derive_verdict` scores
    # `inconclusive` instead of `failed` (see `context/loop.md`). A gate with
    # more than one distinct failing file, or no parseable file at all, is
    # never eligible — the classifier stays `:code` (untagged) and today's
    # `failed` stands unchanged.
    classification =
      cond do
        infra_tag != "" ->
          infra_tag

        exit_code != 0 and exit_code != "timeout" ->
          case single_failing_test_file(output) do
            {:ok, file} ->
              case isolated_rerun_fn.(file, project_dir) do
                {_isolated_output, 0} -> "flake-isolated:" <> file
                {_isolated_output, _nonzero} -> ""
              end

            :ineligible ->
              ""
          end

        true ->
          ""
      end

    {execution_evidence, expected_segments} = evidence_fn.(gate, output)

    witness =
      if exit_code != 0 and exit_code != "timeout", do: extract_witness(log_path), else: ""

    write_script = """
    source #{shell_quote(@gate_result_lib)} && write_gate_result \
      #{shell_quote(gate)} #{shell_quote(mode)} #{shell_quote(base_sha)} #{diff_files_count} \
      true #{exit_code} #{execution_evidence} #{expected_segments} #{shell_quote(render_verdict)} #{shell_quote(classification)} \
      #{shell_quote(started)} #{shell_quote(ended)} \
      #{shell_quote(session_id)} #{shell_quote(log_path)} #{shell_quote(project_dir)} \
      #{shell_quote(witness)} #{shell_quote(tree_sha)} #{shell_quote(cycle_id)}
    """

    {_write_out, 0} = System.cmd("bash", ["-c", write_script], stderr_to_stdout: true)

    marker = gate_verdict_marker(project_dir)
    detail = witness_detail(marker, witness, log_path)
    log_verdict_fn.(cycle_log, gate, mode, marker, detail)

    {read_verdict(project_dir), gate}
  end

  # Runs the static-stack render check (headless Chromium via render-check.js)
  # against `<project_dir>/public`. Returns `{render_verdict_line, combined_output}`.
  #
  # A missing output dir is NEVER silently scored as PASS (`""` used to fall
  # through `_derive_verdict`'s case to `clear`, indistinguishable from "we
  # checked and it passed") — the static stack's own scaffold always writes
  # its build output to `public/` (`shared/scaffold/static/scaffold.sh`
  # `outDir: "public"`), so an absent `public/` after a clear-exit gate
  # command means the build produced NOTHING, which is a build failure, not
  # a skip. Emits `FAIL:no-output` so `_derive_verdict`'s `FAIL:*` arm fires.
  #
  # Never raises for a PRESENT-but-broken render: a crashed/missing
  # render-check is INCONCLUSIVE, not a hard failure — it must never
  # silently masquerade as PASS, but it also must not take down the whole
  # gate on an infra hiccup (chromium missing, etc.).
  defp run_static_render_check(project_dir, gate_output, opts) do
    render_check_fn = Keyword.get(opts, :render_check_fn, &default_render_check_fn/1)
    out_dir = Path.join(project_dir, "public")

    if File.dir?(out_dir) do
      {verdict_line, _exit} = render_check_fn.(project_dir)
      verdict = extract_render_verdict(verdict_line)
      {verdict, gate_output <> "\n" <> verdict_line}
    else
      {"FAIL:no-output", gate_output <> "\nRENDER_VERDICT=FAIL:no-output (public/ dir absent)"}
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

  # Shells `gate-result.sh`'s `extract_witness` against the just-written gate
  # log — the function has existed, been unit-tested six ways
  # (`gate-result_test.sh`), and had ZERO production callers until this call
  # site. Fall-open-empty: any non-zero exit or unparseable log yields ""
  # (never raises, never blocks the gate) — `write_gate_result`'s witness
  # slot already tolerates "" (its historical value here, before this call
  # existed). Only invoked for a genuine opaque non-zero exit (never for
  # "timeout", which already carries its own known reason).
  @spec extract_witness(String.t()) :: String.t()
  defp extract_witness(log_path) do
    unless File.exists?(@gate_result_lib) do
      raise "LoopGate: gate-result.sh not found at #{@gate_result_lib}"
    end

    script = "source #{shell_quote(@gate_result_lib)} && extract_witness #{shell_quote(log_path)}"

    case System.cmd("bash", ["-c", script], stderr_to_stdout: true) do
      {output, 0} -> output
      {_output, _code} -> ""
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
  Reads the `base_sha` field the last `run_gate/2` call stamped into
  `<project_dir>/codegen/gate-pending/gate-result.json` — the cycle-start
  HEAD the gate ran against. Returns `""` when the file/field is absent
  (legacy record, or a gate that hasn't run). Used by
  `OrchestrationLoop`'s resume-checkpoint validity check to confirm HEAD
  has not moved since the gate ran (rules out the rare "commit step
  committed then died before advancing cycle-state to COMMITTED" edge).
  """
  @spec gate_result_base_sha(String.t()) :: String.t()
  def gate_result_base_sha(project_dir) do
    unless File.exists?(@gate_result_lib) do
      raise "LoopGate: gate-result.sh not found at #{@gate_result_lib}"
    end

    script =
      "source #{shell_quote(@gate_result_lib)} && gate_result_base_sha #{shell_quote(project_dir)}"

    {output, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    String.trim(output)
  end

  @doc """
  Reads the `witness` field the last `run_gate/2` call stamped into
  `<project_dir>/codegen/gate-pending/gate-result.json` — the located
  `file:line — <verbatim cause>` for a FAILED verdict (see the Witness
  Discipline rule; `extract_witness/1` is the producer). Returns `""` when
  the file/field is absent, unreadable, or the last gate was clear (no
  failure to locate).

  Used to resolve WHICH ROLE owns a gate failure (see
  `OrchestrationLoop.default_gate_classify_fn/2`'s owner-mapping) and to
  drive the standalone flake re-run: an owner-mapping regex matches against
  this text, never against the raw gate log, so the mapping is scoped to
  the exact located failure rather than incidental noise elsewhere in the
  log.
  """
  @spec failing_check(String.t()) :: String.t()
  def failing_check(project_dir) do
    path = gate_result_path(project_dir)

    with {:ok, contents} <- File.read(path),
         {:ok, %{"witness" => witness}} <- Jason.decode(contents),
         true <- is_binary(witness) do
      witness
    else
      _ -> ""
    end
  end

  @doc """
  Reads the `classification` field the last `run_gate/2` call stamped into
  `<project_dir>/codegen/gate-pending/gate-result.json` — the same tag
  `write_gate_result` threads through to `gate-result.sh`'s
  `_derive_verdict` (`seed-missing*` / `pool-exhaustion*` /
  `flake-isolated:*`). Returns `""` when the file/field is absent,
  unreadable, or no classification applied.

  Used by `OrchestrationLoop.default_gate_classify_fn/2` to detect the
  `flake-isolated:` load-starvation case (Fault 1 / Move 2b) — a distinct
  attempt-budget arm from ordinary rework, mirroring the existing
  `:stale_build` classification's own heal-without-charging shape.
  """
  @spec gate_classification(String.t()) :: String.t()
  def gate_classification(project_dir) do
    path = gate_result_path(project_dir)

    with {:ok, contents} <- File.read(path),
         {:ok, %{"classification" => classification}} <- Jason.decode(contents),
         true <- is_binary(classification) do
      classification
    else
      _ -> ""
    end
  end

  @doc """
  Recomputes the CURRENT working-tree content-hash for `project_dir` — the
  same computation `run_gate/2` stamps at gate time (see `graded_tree_sha/1`
  private helper), exposed publicly so the loop's pre-commit re-check
  (`verify_gate_graded_this_tree/2`) can compare "what the gate graded" vs.
  "what the tree looks like right now, immediately before the deterministic
  commit step runs" without re-running the whole gate.
  """
  @spec graded_tree_sha_now(String.t()) :: String.t()
  def graded_tree_sha_now(project_dir), do: graded_tree_sha(project_dir)

  @doc """
  Writes the cycle-log `{"ev":"gate"}` record for a gate run that was NOT
  performed because an existing `gate-result.json` already grades this exact
  tree, in this exact build, under this exact gate command
  (`OrchestrationLoop`'s cached-gate skip).

  Deliberately the SAME writer as a real gate run's own verdict event
  (`default_log_verdict/5`), with the same argv shape, so the cycle log
  cannot end up with a developer step and a reviewer step and no gate event
  between them — which would read as a bypass to any later auditor. The
  caller distinguishes it by passing a `cached: ...` `detail`.

  Nothing is appended to `gate-verdicts.jsonl`: that ledger is written only
  by `gate-result.sh`'s `write_gate_result`, one row per gate that actually
  ran, and each row carries a `duration_s`. A row for a run that consumed no
  time would over-count exactly the number the `cycle_id` field was added to
  make summable.
  """
  @spec log_cached_verdict(String.t() | nil, String.t(), String.t(), String.t(), String.t()) ::
          :ok
  def log_cached_verdict(cycle_log, gate, mode, marker, detail),
    do: default_log_verdict(cycle_log, gate, mode, marker, detail)

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
  # before the deterministic commit step). "" when project_dir is not a git
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
    path = gate_result_path(project_dir)

    with {:ok, contents} <- File.read(path),
         {:ok, %{"verdict_marker" => marker}} <- Jason.decode(contents),
         true <- is_binary(marker) do
      marker
    else
      _ -> ""
    end
  end

  # Single source of the `gate-result.json` path — reused by the pre-canary
  # unlink in `run_gate/2` and `gate_verdict_marker/1`'s read, so the two
  # never drift.
  @spec gate_result_path(String.t()) :: String.t()
  defp gate_result_path(project_dir) do
    Path.join(project_dir, "codegen/gate-pending/gate-result.json")
  end

  # Default :log_verdict_fn — shells `codegen-log verdict` against
  # `cycle_log` via CODEGEN_LOG_PATH. nil cycle_log (no log initialized,
  # e.g. most unit tests) or an empty marker (gate_verdict_marker/1 could
  # not read one) → silent no-op, never an error. A non-zero codegen-log
  # exit is fail-loud-non-blocking: this is an observability write, and
  # must never flip the gate's own verdict.
  @spec default_log_verdict(String.t() | nil, String.t(), String.t(), String.t(), String.t()) ::
          :ok
  defp default_log_verdict(nil, _gate, _mode, _marker, _detail), do: :ok
  defp default_log_verdict(_cycle_log, _gate, _mode, "", _detail), do: :ok

  defp default_log_verdict(cycle_log, gate, mode, marker, detail) do
    unless File.exists?(@codegen_log_bin) do
      IO.puts(
        :stderr,
        "LoopGate: codegen-log not found at #{@codegen_log_bin} — verdict not logged"
      )

      :ok
    else
      argv =
        ["verdict", "--gate", gate, "--mode", mode, "--result", marker] ++
          if detail != "", do: ["--detail", detail], else: []

      {output, exit_code} =
        System.cmd(
          @codegen_log_bin,
          argv,
          stderr_to_stdout: true,
          env: [{"CODEGEN_DIR", @codegen_dir}, {"CODEGEN_LOG_PATH", cycle_log}]
        )

      if exit_code != 0 do
        IO.puts(:stderr, "LoopGate: codegen-log verdict failed (#{exit_code}): #{output}")
      end

      :ok
    end
  end

  # Derives the durable `--detail` text for the cycle log's `{"ev":"gate"}`
  # event. A non-empty `witness` (already computed at `run_gate/2`'s call
  # site via `extract_witness/1`) wins outright — it is the located cause.
  # On a CLEAR verdict marker, no detail is needed (there is no failure to
  # explain) — empty string, matching `default_log_verdict/5`'s existing
  # no-op-on-empty-marker/nil-cycle_log behavior.
  #
  # A non-clear marker with an EMPTY witness must never durably record `""`
  # — that is exactly the blindness this function exists to close (see the
  # pitch's claim ledger #16: `extract_witness` legitimately returns `""`
  # on unparseable/coverage-noise output, on a genuinely empty gate log, and
  # on a missing log file). Each of those is itself a real, distinct
  # diagnosis, so it is recorded as a named sentinel rather than silently
  # dropped.
  @spec witness_detail(String.t(), String.t(), String.t()) :: String.t()
  defp witness_detail(marker, witness, log_path) do
    cond do
      witness != "" ->
        witness

      marker == "" or marker == "ALL CLEAR ✅" ->
        ""

      true ->
        case File.stat(log_path) do
          {:ok, %File.Stat{size: 0}} ->
            "gate produced no output"

          {:ok, %File.Stat{size: size}} ->
            "no parseable failure location in #{size}-byte gate log"

          {:error, _reason} ->
            "gate produced no output"
        end
    end
  end

  # Real :run_fn. Spawns the gate command via `Port.open` (rather than the
  # simpler blocking `System.cmd`) so its OS pid is discoverable via
  # `Port.info/2` WHILE it is still running — `run_with_deadline/4` needs
  # this to target-kill the real subprocess on expiry; a blocking
  # `System.cmd` call exposes no os_pid until it has already returned.
  #
  # `Port.open`'s `:env` option only ever ADDS/overrides on top of the OS's
  # already-inherited environment — passing a REDUCED key list (e.g. via
  # `Map.drop/2`) does NOT unset the dropped keys in the child (confirmed by
  # direct probe: the child still saw every ambient `CODEGEN_BUILD_*` var).
  # The actual unset token, mirrored from `System.cmd`'s own
  # `validate_env/1` (`{key, nil}` → `{charlist_key, false}`), is what
  # `Port.open` itself recognizes as "delete this inherited var" — so each
  # `CODEGEN_BUILD_*` key must be passed explicitly as `{key, false}`, not
  # simply omitted from the list.
  defp default_run_fn(gate_command, project_dir) do
    env =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "CODEGEN_BUILD_"))
      |> Enum.map(&{String.to_charlist(&1), false})

    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["-c", gate_command]},
        {:cd, project_dir},
        {:env, env}
      ])

    Process.put(:codegen_gate_port, port)
    collect_port_output(port, [])
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, chunk}} ->
        collect_port_output(port, [chunk | acc])

      {^port, {:exit_status, code}} ->
        {IO.iodata_to_binary(Enum.reverse(acc)), code}
    end
  end

  # Bounds `run_fn.(gate, project_dir)` with a real deadline instead of the
  # historical bare, unbounded blocking call. `timeout` <= 0 means "no
  # budget declared" (`gate_timeout_for`'s truthful fallthrough for
  # `make test` and any unrecognized command) — NEVER enforced literally;
  # floored to `@default_short_gate_timeout` here, in the CONSUMER, so
  # `gate-select.sh`'s own `0` contract and its green test
  # (`gate-select_test.sh:46`) stay untouched. `run_fn` itself stays 2-arity
  # — widening it would break the 22 existing 2-arity test seams and the
  # shape the dependent canary pitch builds against; the deadline wraps the
  # call instead, bounding injected seams too, for free.
  #
  # On expiry: kills the Elixir Task AND, when it was the real
  # `default_run_fn` running (it records its port in the Task process's own
  # dictionary via `Process.put/2` before blocking), the spawned OS process
  # tree via `Port.info/2`'s os_pid — a plain `Task.shutdown` alone would
  # leave `default_run_fn`'s real subprocess running detached, chewing CPU
  # while the loop reports INCONCLUSIVE. Test-injected `run_fn` seams (which
  # never spawn a real OS child) simply have no port to find and are fully
  # reclaimed by the Task kill alone.
  #
  # This deliberately does NOT reuse `LoopQueueDrain.reap_own_descendants/0`
  # (the solo top-level build path's whole-BEAM descendant reap): that
  # helper scans and kills EVERY OS descendant of the CURRENT BEAM
  # (`System.pid()`), which is safe only when the calling BEAM IS the
  # top-level build process with no unrelated concurrent work. Called from
  # inside `run_gate/2` — which also runs under a live ExUnit suite with
  # many concurrent async tests/subprocesses of its own — it kills unrelated
  # sibling work: confirmed by direct probe (invoking it from a test here
  # crashed the whole BEAM). Killing only the specific spawned os_pid is
  # scoped and safe regardless of what else the calling BEAM is doing.
  #
  # Returns `{"", "timeout"}`, which feeds `_derive_verdict`'s already-written
  # `exit_code = "timeout" → inconclusive` arm (previously unreachable).
  @spec run_with_deadline(
          (String.t(), String.t() -> {String.t(), integer()}),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {String.t(), integer() | String.t()}
  defp run_with_deadline(run_fn, gate, project_dir, timeout) do
    effective_timeout = if timeout > 0, do: timeout, else: @default_short_gate_timeout

    task = Task.async(fn -> run_fn.(gate, project_dir) end)

    case Task.yield(task, effective_timeout * 1_000) do
      {:ok, result} ->
        result

      nil ->
        kill_task_os_child(task.pid)
        Task.shutdown(task, :brutal_kill)
        {"", "timeout"}
    end
  end

  # Best-effort: if the timed-out Task recorded a `Port` (only `real`
  # `default_run_fn` does), kill that port's OS process directly — a single
  # `kill -9` on the exact pid, never a system-wide scan. No-op (silently)
  # when the Task never ran `default_run_fn`, already exited, or the OS
  # already reaped the process — this is a best-effort cleanup on the
  # already-decided timeout path, not a source of new failures.
  defp kill_task_os_child(task_pid) do
    case Process.info(task_pid, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, :codegen_gate_port) do
          nil ->
            :ok

          port ->
            case Port.info(port, :os_pid) do
              {:os_pid, os_pid} ->
                System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
                :ok

              nil ->
                :ok
            end
        end

      nil ->
        :ok
    end
  end

  # Default `:evidence_fn` — derives `{execution_evidence, expected_segments}`
  # from the gate command string and its own output, feeding
  # `gate-result.sh`'s no-op-gate detector real counted operands in place of
  # the historical hardcoded `1 1`.
  #
  # `expected_segments`: the number of `&&`-chained sub-commands in
  # `gate_command` — a single command (`"make test"`) is 1 segment; a
  # chained gate (`"make ci && make llm"`, per `gate-select.sh`'s own
  # documented gate strings) is N segments, one per `&&`.
  #
  # `execution_evidence`: the count of recognized runner-summary footers in
  # `gate_output` — ExUnit's `N tests, N failures` and the codegen hook
  # runner's `N passed, N failed` (`run-tests.sh:75`, an existing pattern —
  # this is a second caller, not a new parser). Falls back to 1 (never 0)
  # when the output is non-empty but carries no recognized footer — many
  # gates (`npm run build`, `mix format --check-formatted`) print no
  # test-count footer at all, and this detector's ONLY job is to catch a
  # gate that produced a truly EMPTY log while exiting 0 (the historical
  # `1 1` incident) — not to police every gate's specific output shape.
  @spec default_evidence(String.t(), String.t()) :: {non_neg_integer(), non_neg_integer()}
  defp default_evidence(gate_command, gate_output) do
    expected_segments =
      gate_command
      |> String.split(~r/\s*&&\s*/)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> length()
      |> max(1)

    footer_count =
      Regex.scan(~r/\d+\s+tests?,\s*\d+\s+failures?|\d+\s+passed,\s*\d+\s+failed/, gate_output)
      |> length()

    execution_evidence =
      cond do
        footer_count > 0 -> footer_count
        String.trim(gate_output) != "" -> 1
        true -> 0
      end

    {execution_evidence, expected_segments}
  end

  # Default `:canary_fn` — asks `gate-result.sh`'s `_derive_verdict` to grade
  # a KNOWN-BAD input: the real gate command's own `evidence_fn`-derived
  # `{execution_evidence, expected_segments}` for an EMPTY gate log (via
  # `default_evidence/2`'s own fallback branch, execution_evidence for ""
  # is always 0 — a gate that produced no output produced no evidence of
  # running). A gate that ran nothing must always be `:failed`; if
  # `_derive_verdict` returns anything else, the no-op-gate detector is
  # disarmed (constant evidence baked to a truthy value regardless of
  # output — the historical `1 1` incident — or `expected_segments` zeroed
  # — both are the SAME shape of bug this canary exists to catch) and
  # `run_gate/2` raises `CanaryError` rather than certify a verdict from a
  # gate that cannot fail.
  #
  # Deliberately calls `evidence_fn` (the real production seam), NOT a
  # hand-written pair of operands — a canary asserting on its own
  # hand-picked bad numbers proves only that `_derive_verdict` the FUNCTION
  # can fail, which `gate-result_test.sh` already does and already did
  # while production was disarmed. This calls the actual production path
  # with the actual gate command, so a regression in `evidence_fn` itself
  # (not just in `_derive_verdict`) is caught too.
  @spec default_canary(
          String.t(),
          (String.t(), String.t() -> {non_neg_integer(), non_neg_integer()})
        ) :: verdict() | :inconclusive
  defp default_canary(gate_command, evidence_fn) do
    {execution_evidence, expected_segments} = evidence_fn.(gate_command, "")

    unless File.exists?(@gate_result_lib) do
      raise "LoopGate: gate-result.sh not found at #{@gate_result_lib}"
    end

    script =
      "source #{shell_quote(@gate_result_lib)} && _derive_verdict true 0 " <>
        "#{execution_evidence} #{expected_segments} '' ''"

    case System.cmd("bash", ["-c", script], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/^verdict=(\w+)$/m, output) do
          [_, "clear"] -> :clear
          [_, "failed"] -> :failed
          [_, "inconclusive"] -> :inconclusive
          _ -> :clear
        end

      {_output, _code} ->
        :clear
    end
  end

  # Maps `classify_failure/1`'s boolean-ish `:code | :infra` result to the
  # tag string `gate-result.sh`'s `_derive_verdict` case-matches on
  # (`seed-missing*` / `pool-exhaustion*`). `:code` -> `""` (no
  # classification — the exit stays plain `:failed`, not laundered).
  @spec infra_classification_tag(String.t()) :: String.t()
  defp infra_classification_tag(output) do
    case classify_failure(output) do
      :infra -> "pool-exhaustion:generic-infra-fault"
      :code -> ""
    end
  end

  # ExUnit failure-block anchor: "  N) test ..." headline, requiring a bare
  # `file:line` on the very next non-blank line — mirrors the same
  # false-positive guard `gate-result.sh`'s `extract_witness` already uses
  # (a numbered list that is not an ExUnit failure block never matches).
  @exunit_failure_location ~r/^[[:space:]]*\d+\)[[:space:]].*\n[[:space:]]*([A-Za-z0-9_.\/-]+\.exs?):\d+[[:space:]]*$/m

  @doc """
  Fault 1 / Move 2a helper: parses `gate_output` for ExUnit failure blocks
  and returns `{:ok, file}` ONLY when every failure block names the SAME
  single test file — the shape a load-starvation flake produces (one file's
  tests fail under `--max-cases` concurrency, nothing else in the suite is
  touched). Returns `:ineligible` when zero failure blocks are parseable, or
  when two or more DISTINCT files are named — a multi-file failure is never
  isolated-rerun-eligible; the ordinary `failed` classification stands.
  """
  @spec single_failing_test_file(String.t()) :: {:ok, String.t()} | :ineligible
  def single_failing_test_file(gate_output) when is_binary(gate_output) do
    files =
      @exunit_failure_location
      |> Regex.scan(gate_output, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    case files do
      [file] -> {:ok, file}
      _ -> :ineligible
    end
  end

  # Default `:isolated_rerun_fn` — re-runs the single named test file ALONE
  # via `mix test <file>` in `project_dir`. Bounded to one file, once: the
  # caller (`run_gate/2`) invokes this at most once per gate run, never in a
  # retry loop. Uses `MIX_BUILD_PATH=_build/isolated_rerun` so this probe
  # compile never races the gate's own already-completed build (see
  # `context/development.md` § Mix build-path assignment).
  @spec default_isolated_rerun_fn(String.t(), String.t()) :: {String.t(), non_neg_integer()}
  defp default_isolated_rerun_fn(file, project_dir) do
    System.cmd("mix", ["test", file],
      cd: project_dir,
      stderr_to_stdout: true,
      env: [{"MIX_BUILD_PATH", "_build/isolated_rerun"}]
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
