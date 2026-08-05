defmodule CodegenTestHarness.Fixtures do
  @moduledoc """
  Shared fixtures and helpers for stack scaffold tests.

  `harness/0` returns the harness under test (`"claude"`).

  `codegen_build_path/0` returns the absolute path to the `codegen-build`
  script in the OCG repo root.

  `isolated_tmp_dir/0` creates a git-initialised temp directory outside the
  OCG working tree, registers an `on_exit` cleanup, and returns the path.
  Use this instead of `@tag :tmp_dir` to prevent build agents from committing
  to OCG `main`.

  `run_codegen_build/3` centralises the `System.cmd` invocation: builds
  with `--harness`, `--stack`, `--cwd`, and the given prompt; asserts exit 0;
  returns the output string. `codegen-build` always drives the deterministic
  Elixir orchestration loop (the sole engine these stack tests exercise) —
  there is no engine flag to pass.

  `change_request/4` runs two sequential `codegen-build` calls in `cwd`:
  the first scaffolds the app, the second applies the change request.
  Returns `{commits_before, commits_after}` where both are commit-count integers.

  When `BENCH_RUN_DIR` env var is set, each `run_codegen_build/3` call writes
  the captured stdout as JSONL to
  `<BENCH_RUN_DIR>/runs/<harness>/<stack>/<test_name>.jsonl` and appends a
  synthetic `harness_summary` record as the last line. For static stacks
  (`:static`), a
  full-page PNG screenshot is also captured to
  `<BENCH_RUN_DIR>/runs/<harness>/<stack>/<test_name>.png` via
  `BenchArtifacts.capture_screenshot/4`. Screenshot failures are non-fatal.
  Pass `test_name:` in opts to identify the call site (default: `"unnamed"`).
  """

  alias CodegenTestHarness.BenchArtifacts
  alias CodegenTestHarness.BenchCommon
  alias CodegenTestHarness.BenchManifest
  alias CodegenTestHarness.UsageParser

  @codegen_build Path.expand("../../../codegen-build", __DIR__)
  @codegen_call Path.expand("../../../codegen-call", __DIR__)
  @codegen_scaffold Path.expand("../../../codegen-scaffold", __DIR__)
  @config_yaml Path.expand("../../../templates/generator/config.yaml", __DIR__)
  @codegen_build_timeout_ms 5_400_000
  @parity_build_timeout_ms 1_800_000

  @doc """
  Creates an isolated, git-initialised temporary directory outside the OCG
  working tree, registers an `on_exit` cleanup hook, and returns the path.

  Use this in a `setup` block instead of `@tag :tmp_dir` to prevent
  `codegen-build` agents from committing to OCG `main` (the `:tmp_dir` tag
  creates directories inside `test_harness/tmp/`, still inside OCG's git tree,
  so a build agent's `git commit` can walk up to OCG and land on `main`).

  The directory is initialised with an empty root commit so that downstream
  `git log` assertions find a valid history.

  Raises if `git init` or the sentinel `git commit` fails.
  """
  @spec isolated_tmp_dir(keyword()) :: String.t()
  def isolated_tmp_dir(opts \\ []) do
    path =
      Path.join([
        System.tmp_dir!(),
        "codegen_harness_#{:os.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
      ])

    File.mkdir_p!(path)

    File.mkdir_p!(Path.join(path, ".claude"))

    File.write!(Path.join(path, ".claude/settings.json"), ~s({"includeCoAuthoredBy": false}))

    agents_src = Path.expand("~/.claude/agents")
    agents_dst = Path.join(path, ".claude/agents")

    if File.dir?(agents_src) do
      File.cp_r!(agents_src, agents_dst)
    end

    phoenix_scaffold_section =
      if Keyword.get(opts, :stack) != :phoenix do
        """

        For Phoenix apps: scaffold INTO the current directory using `echo "y" | mix phx.new . --app <name> --live` (e.g. `echo "y" | mix phx.new . --app hello_world --live`). The `echo "y"` is REQUIRED because the directory already exists and Phoenix will prompt for confirmation. NEVER use `mix phx.new <name>` — that creates a subdirectory instead of scaffolding here.
        """
      else
        ""
      end

    claude_md_base = """
    # Project Root

    This is the project directory. Write ALL output files here using relative paths.

    NEVER use `cd /tmp` or absolute `/tmp/` paths for project output files.
    NEVER run `mix phx.new /tmp/<name>` — use `mix phx.new <name>` (relative) so the app lands under this directory.
    NEVER write HTML, Elixir, config, or any project file to an absolute path outside this directory.

    Use the Write tool with relative paths (e.g. `static/index.html`, `lib/my_app/foo.ex`).
    From Bash: create files relative to current directory, never `cat > /tmp/<file>`.
    """

    File.write!(Path.join(path, "CLAUDE.md"), claude_md_base <> phoenix_scaffold_section)

    unless System.get_env("KEEP_TMP") == "1" do
      ExUnit.Callbacks.on_exit(fn -> rm_rf_resilient(path) end)
    else
      IO.puts(:stderr, "KEEP_TMP=1 — preserving tmp dir: #{path}")
    end

    case Keyword.get(opts, :stack) do
      :phoenix ->
        phoenix_path = scaffold_phoenix_app!(path)

        File.mkdir_p!(Path.join(phoenix_path, ".claude"))

        File.write!(
          Path.join(phoenix_path, ".claude/settings.json"),
          ~s({"includeCoAuthoredBy": false})
        )

        if File.dir?(agents_src) do
          File.cp_r!(agents_src, Path.join(phoenix_path, ".claude/agents"))
        end

        commit_fixture_baseline!(phoenix_path, "chore: fixture phoenix baseline")
        phoenix_path

      _ ->
        ensure_git_repo!(path)
        commit_fixture_baseline!(path, "init")
        path
    end
  end

  @doc "Returns the harness under test."
  @spec harness() :: String.t()
  def harness do
    BenchCommon.detect_harness()
  end

  @doc """
  Returns the harness name in the form accepted by `codegen-call` (`--harness` flag).

  `codegen-call` accepts `"claude_code"`. The `harness/0` function returns
  `"claude"` (the short form used by `codegen-build`). This function maps `"claude"` →
  `"claude_code"` and passes other values through unchanged.
  """
  @spec codegen_call_harness() :: String.t()
  def codegen_call_harness do
    case harness() do
      "claude" -> "claude_code"
      other -> other
    end
  end

  @doc "Returns the absolute path to the `codegen-build` script."
  @spec codegen_build_path() :: String.t()
  def codegen_build_path do
    unless File.exists?(@codegen_build) do
      raise "codegen-build not found at #{@codegen_build}"
    end

    @codegen_build
  end

  @doc "Returns the absolute path to the `codegen-call` script."
  @spec codegen_call_path() :: String.t()
  def codegen_call_path do
    unless File.exists?(@codegen_call) do
      raise "codegen-call not found at #{@codegen_call}"
    end

    @codegen_call
  end

  @doc """
  Runs `codegen-scaffold create --stack=phoenix --cwd=<parent> --slug=<slug> --no-ecto`
  and returns the path to the scaffolded app directory.

  The `--no-ecto` flag is unconditional — use this fixture only for no-ecto
  scaffold tests. For general scaffold invocations, extend with a flags opt.

  Raises if the scaffold exits non-zero.
  """
  @spec run_no_ecto_scaffold(String.t(), keyword()) :: String.t()
  def run_no_ecto_scaffold(parent, opts) do
    slug = Keyword.fetch!(opts, :slug)

    unless File.exists?(@codegen_scaffold) do
      raise "codegen-scaffold not found at #{@codegen_scaffold}"
    end

    {output, exit_code} =
      System.cmd(
        @codegen_scaffold,
        ["create", "--stack=phoenix", "--cwd=#{parent}", "--slug=#{slug}", "--no-ecto"],
        stderr_to_stdout: true
      )

    if exit_code != 0 do
      raise "codegen-scaffold failed (exit=#{exit_code}):\n#{output}"
    end

    Path.join(parent, slug)
  end

  @doc """
  Invokes `codegen-call` with a structured JSON schema and returns the
  decoded envelope map.

  `opts`:
  - `:role` — string role name (required)
  - `:system_prompt` — string system prompt (required)

  Model and effort are resolved from `templates/generator/config.yaml` using
  the harness-specific key (`.harness.<role>.<harness_short>.model`).

  Raises on non-zero exit from codegen-call.
  """
  @spec run_codegen_call(String.t(), String.t(), keyword()) :: map()
  def run_codegen_call(prompt, schema, opts) do
    # codegen-call accepts "claude_code"; map "claude" → "claude_code".
    harness_val = codegen_call_harness()
    role = Keyword.fetch!(opts, :role)
    system_prompt = Keyword.fetch!(opts, :system_prompt)

    # Map harness_val back to config.yaml key ("claude_code" → "claude").
    config_harness = if harness_val == "claude_code", do: "claude", else: harness_val

    model = config_yaml_read!(".harness.#{role}.#{config_harness}.model")
    effort = config_yaml_read!(".harness.#{role}.#{config_harness}.effort")

    # codegen-call requires @<abs-path> for system-prompt and json-schema.
    sp_path = write_tmp_file!(system_prompt, ".txt")
    schema_path = write_tmp_file!(schema, ".json")

    err_path =
      Path.join(
        System.tmp_dir!(),
        "codegen-call-stderr-#{System.unique_integer([:positive])}.log"
      )

    try do
      # Stream split (not merged): the envelope lives on stdout alone — a
      # stderr diagnostic line landing in front of it would corrupt the JSON
      # parse. `exec "$@" 2>"$CG_ERR"` replaces the shell in place (no extra
      # process layer); stderr is captured to a temp file and re-emitted
      # below so it still reaches the caller's own stderr/log capture.
      {output, exit_code} =
        System.cmd(
          "sh",
          [
            "-c",
            ~s(exec "$@" 2>"$CG_ERR"),
            "sh",
            codegen_call_path(),
            "--harness=#{harness_val}",
            "--model=#{model}",
            "--effort=#{effort}",
            "--system-prompt=@#{sp_path}",
            "--json-schema=@#{schema_path}",
            prompt
          ],
          env: [{"CG_ERR", err_path}],
          stderr_to_stdout: false
        )

      stderr =
        case File.read(err_path) do
          {:ok, content} -> content
          {:error, _reason} -> ""
        end

      if stderr != "", do: IO.write(:stderr, stderr)

      if exit_code != 0 do
        raise "codegen-call failed (exit=#{exit_code}):\n#{output}\n#{stderr}"
      end

      case Jason.decode(output) do
        {:ok, decoded} ->
          decoded

        {:error, decode_error} ->
          received = String.slice(output, 0, 200)
          stderr_tail = String.slice(stderr, max(String.length(stderr) - 200, 0), 200)

          raise "Fixtures.run_codegen_call: expected JSON envelope on codegen-call stdout, " <>
                  "got: #{inspect(received)} (decode error: #{Exception.message(decode_error)}); " <>
                  "stderr tail: #{inspect(stderr_tail)}"
      end
    after
      File.rm(sp_path)
      File.rm(schema_path)
      File.rm(err_path)
    end
  end

  # Reads a scalar value from templates/generator/config.yaml using yq.
  # Raises if yq is not on PATH or if the key is missing/empty.
  defp config_yaml_read!(key) do
    {value, code} = System.cmd("yq", ["-r", key, @config_yaml], stderr_to_stdout: true)
    value = String.trim(value)

    if code != 0 or value == "" or value == "null" do
      raise "config.yaml key #{key} missing or unreadable (exit=#{code}, value=#{inspect(value)})"
    end

    value
  end

  # Writes content to a temp file with the given suffix and returns its path.
  defp write_tmp_file!(content, suffix) do
    path =
      Path.join(System.tmp_dir!(), "codegen_call_#{:erlang.unique_integer([:positive])}#{suffix}")

    File.write!(path, content)
    path
  end

  @doc """
  Runs `render-check.js` against `cwd` and returns a render verdict tuple.

  Returns:
  - `{:pass}` — render checks passed
  - `{:fail, reason}` — render check failed
  - `{:inconclusive, reason}` — browser/server absent or other non-fatal miss

  `mode` is `:phoenix` or `:static`.
  """
  @type render_verdict() :: {:pass} | {:fail, String.t()} | {:inconclusive, String.t()}
  @spec render_verdict(String.t(), :phoenix | :static) :: render_verdict()
  def render_verdict(cwd, mode) do
    script = Path.expand("../../../harnesses/claude/hooks/lib/render-check.js", __DIR__)
    codegen_dir = Path.expand("../../..", __DIR__)

    {output, _exit_code} =
      case mode do
        :phoenix ->
          System.cmd(
            "node",
            [script, "--mode", "phoenix", "--spawn", cwd],
            cd: cwd,
            stderr_to_stdout: false,
            env: [{"CODEGEN_DIR", codegen_dir}]
          )

        :static ->
          built_dir =
            cond do
              File.exists?(Path.join(cwd, "public/index.html")) -> Path.join(cwd, "public")
              true -> cwd
            end

          System.cmd(
            "node",
            [script, "--mode", "static", built_dir],
            cd: cwd,
            stderr_to_stdout: false,
            env: [{"CODEGEN_DIR", codegen_dir}]
          )
      end

    parse_render_verdict(output)
  end

  @spec parse_render_verdict(String.t()) :: render_verdict()
  defp parse_render_verdict(output) do
    case Regex.run(~r/RENDER_VERDICT=(.+)/, output) do
      [_, "PASS"] ->
        {:pass}

      [_, "FAIL:" <> reason] ->
        {:fail, reason}

      [_, "INCONCLUSIVE:" <> reason] ->
        {:inconclusive, reason}

      _ ->
        {:inconclusive, "no verdict line"}
    end
  end

  @doc """
  Runs `codegen-build` with the given stack and prompt in `cwd`.

  Asserts exit 0 and returns the combined stdout+stderr output string.

  `opts` may include:
  - `stack:` (string, default `"phoenix"`)
  - `test_name:` (string, default `"unnamed"`) — stable identifier written to
    the benchmark JSONL file when `BENCH_RUN_DIR` is set
  """
  @spec run_codegen_build(String.t(), String.t(), keyword()) :: String.t()
  def run_codegen_build(cwd, prompt, opts \\ []) do
    harness_val = harness()
    stack = Keyword.get(opts, :stack, "phoenix")
    test_name = Keyword.get(opts, :test_name, "unnamed")

    prepare_codegen_build_baseline!(cwd, stack)

    build_started_at = System.monotonic_time(:millisecond)

    {output, exit_code} =
      run_with_timeout(
        codegen_build_path(),
        [
          "--harness=#{harness_val}",
          "--stack=#{stack}",
          "--cwd=#{cwd}",
          prompt
        ],
        [],
        @codegen_build_timeout_ms
      )

    build_duration_ms = System.monotonic_time(:millisecond) - build_started_at

    invocation_index = Process.get(:codegen_build_invocation, 1)
    maybe_write_diagnostics(output, invocation_index)
    Process.put(:codegen_build_invocation, invocation_index + 1)

    maybe_write_bench_record(output, exit_code, harness_val, stack, test_name, build_duration_ms)

    if exit_code == 0, do: maybe_capture_screenshot(cwd, stack, test_name)

    if exit_code != 0 do
      raise "codegen-build failed (harness=#{harness_val}, stack=#{stack}, exit=#{exit_code}):\n#{output}"
    end

    output
  end

  @doc """
  Harness-parameterized, custom-timeout, non-raising twin of `run_codegen_build/3`.
  Drives a single harness so the parity test can run BOTH in one test body and
  compare observable contracts. Returns `{exit_code, output}` — does NOT raise on
  non-zero exit (the parity test inspects exit codes itself). Always exercises
  the loop, same as `run_codegen_build/3` — `codegen-build` has no engine flag.
  """
  @spec run_codegen_build_parity(String.t(), String.t(), String.t(), keyword()) ::
          {non_neg_integer(), String.t()}
  def run_codegen_build_parity(cwd, harness, prompt, opts \\ []) do
    stack = Keyword.get(opts, :stack, "phoenix")
    timeout_ms = Keyword.get(opts, :timeout_ms, @parity_build_timeout_ms)

    prepare_codegen_build_baseline!(cwd, stack)

    {output, exit_code} =
      run_with_timeout(
        codegen_build_path(),
        [
          "--harness=#{harness}",
          "--stack=#{stack}",
          "--cwd=#{cwd}",
          prompt
        ],
        [],
        timeout_ms
      )

    {exit_code, output}
  end

  # Runs the same `codegen-scaffold integrate` stage codegen-build runs as its
  # pre-step, then commits whatever it wired, so the tree is CLEAN when the
  # loop starts.
  #
  # Why this must happen test-side rather than inside codegen-build:
  # codegen-build's integrate pre-step documents "The LLM then commits these
  # along with the app code" — an assumption from the in-harness
  # self-orchestration era. OrchestrationLoop.preflight_clean_tree!/1 (which
  # subsumed that surface) now aborts the cycle BEFORE turn 0 unless the tree
  # is clean, so integrate's own output (PROJECT_CONTEXT.md, restart_server.sh,
  # Makefile, context/, .gitignore, codegen/ symlinks) made every
  # scaffold-from-empty-dir build die in ~1s with exit=1 and zero model turns.
  #
  # Production never hits this: the consuming platform provisions the app dir
  # and commits BEFORE calling codegen-build, so integrate is an idempotent no-op there and
  # the tree is already clean. This mirrors that provisioning contract for the
  # fixture. Running integrate here also makes codegen-build's own pre-step a
  # no-op (it is guarded by existence checks), so the build path is unchanged.
  #
  # Commit-count safety: `change_request/4` snapshots commits_before AFTER the
  # first build, and integrate is idempotent, so this commit can never inflate
  # the {commits_before, commits_after} delta the iteration tests assert on.
  @doc """
  Runs the deterministic pre-cycle scaffold integration and commits its output.

  The orchestration loop rejects any dirty tree before turn 0. `codegen-build`
  also runs `codegen-scaffold integrate` as a pre-step, so tests that call the
  loop through either normal or parity helpers must make that stage a committed
  baseline before the loop starts.
  """
  @spec prepare_codegen_build_baseline!(String.t(), String.t()) :: :ok
  def prepare_codegen_build_baseline!(cwd, stack) do
    if File.exists?(@codegen_scaffold) do
      System.cmd(@codegen_scaffold, ["integrate", "--stack=#{stack}", "--cwd=#{cwd}"],
        stderr_to_stdout: true
      )
    end

    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true)

    if String.trim(status) != "" do
      {_, 0} = System.cmd("git", ["add", "-A"], cd: cwd, env: git_env(), stderr_to_stdout: true)

      {_, 0} =
        System.cmd("git", ["commit", "-m", "chore: wire codegen scaffold"],
          cd: cwd,
          env: git_env(),
          stderr_to_stdout: true
        )
    end

    :ok
  end

  @doc """
  Runs two sequential `codegen-build` calls in `cwd`:
    1. `first_prompt` — scaffolds the app
    2. `second_prompt` — applies the change request

  Returns `{commits_before, commits_after}` where each value is the git commit
  count after the respective build.

  When `test_name:` is in opts, the two calls use `<test_name>_scaffold` and
  `<test_name>_change` as their individual names for bench JSONL output.
  """
  @spec change_request(String.t(), String.t(), String.t(), keyword()) ::
          {non_neg_integer(), non_neg_integer()}
  def change_request(cwd, first_prompt, second_prompt, opts \\ []) do
    base_name = Keyword.get(opts, :test_name, "unnamed")
    first_opts = Keyword.put(opts, :test_name, "#{base_name}_scaffold")
    second_opts = Keyword.put(opts, :test_name, "#{base_name}_change")

    run_codegen_build(cwd, first_prompt, first_opts)
    commits_before = count_commits!(cwd)

    run_codegen_build(cwd, second_prompt, second_opts)
    commits_after = count_commits!(cwd)

    {commits_before, commits_after}
  end

  @doc """
  Runs the mode launcher for the given harness and mode non-interactively.

  For the `claude` harness: calls `claude --print` directly with the
  appropriate system prompt, bypassing `{harness}-{mode}.sh` which requires
  interactive stdin.

  For any other harness: delegates to `{harness}-{mode}.sh` as before.

  Returns `{output, exit_code}` — does NOT raise on failure (callers inspect
  exit_code themselves).

  Mode is an atom: :debug | :shape

  `opts` may include:
  - `test_name:` (string, default `"<mode>_mode"`) — stable identifier written to
    the benchmark JSONL file when `BENCH_RUN_DIR` is set
  """
  @spec run_mode_launcher(String.t(), atom(), String.t(), keyword()) ::
          {String.t(), non_neg_integer()}
  def run_mode_launcher(cwd, mode, prompt, opts \\ []) do
    harness_val = harness()
    mode_str = Atom.to_string(mode)
    test_name = Keyword.get(opts, :test_name, "#{mode_str}_mode")

    build_started_at = System.monotonic_time(:millisecond)

    {output, exit_code} =
      case harness_val do
        "claude" ->
          codegen_dir = Path.expand("../../..", __DIR__)

          sp_file =
            Path.join([
              codegen_dir,
              "harnesses",
              harness_val,
              "#{harness_val}-#{mode_str}-system-prompt.txt"
            ])

          unless File.exists?(sp_file) do
            raise "system prompt not found at #{sp_file}"
          end

          system_prompt = File.read!(sp_file)

          System.cmd(
            "claude",
            [
              "--print",
              "--dangerously-skip-permissions",
              "--system-prompt",
              system_prompt,
              prompt
            ],
            cd: cwd,
            stderr_to_stdout: true
          )

        _ ->
          script =
            Path.expand(
              "../../../harnesses/#{harness_val}/#{harness_val}-#{mode_str}.sh",
              __DIR__
            )

          unless File.exists?(script) do
            raise "mode launcher not found at #{script}"
          end

          shell_quote = fn arg ->
            "'" <> String.replace(arg, "'", "'\\''") <> "'"
          end

          shell_cmd =
            "env PI_NON_INTERACTIVE=1 " <>
              shell_quote.(script) <>
              " " <>
              shell_quote.(prompt) <> " </dev/null"

          deadline = System.monotonic_time(:millisecond) + 1_800_000
          port = Port.open({:spawn, shell_cmd}, [:binary, :exit_status, {:cd, cwd}])
          collect_port_output(port, [], deadline)
      end

    build_duration_ms = System.monotonic_time(:millisecond) - build_started_at

    maybe_write_mode_bench_record(
      output,
      exit_code,
      harness_val,
      "modes",
      test_name,
      build_duration_ms
    )

    {output, exit_code}
  end

  @doc """
  Writes a minimal Shape Up pitch skeleton to
  `{cwd}/codegen/pitches/draft/{slug}.md`. Creates parent directories.
  Returns the path written.
  """
  @spec write_stub_pitch!(String.t(), String.t()) :: String.t()
  def write_stub_pitch!(cwd, slug) do
    dir = Path.join([cwd, "codegen", "pitches", "draft"])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{slug}.md")

    File.write!(path, """
    # Pitch: #{slug}

    ## Problem

    The project's test suite runs all hook tests sequentially in a single shell
    process, making CI feedback slow. Each test takes 2–5 seconds; with 40 tests,
    total wall time exceeds 3 minutes. Engineers wait too long for local feedback.

    ## Appetite

    Small batch — 1 week.
    """)

    path
  end

  # ── Private helpers ───────────────────────────────────────────────────────────
  @doc """
  Writes `output` to the file named by `DIAGNOSTICS_FILE` env var, if set.

  The `{N}` placeholder in the filename is replaced with `invocation_index`,
  so repeated calls (e.g. from `change_request/4`) produce distinct files:
  `prefix-{N}.jsonl` → `prefix-1.jsonl`, `prefix-2.jsonl`, etc.

  When `DIAGNOSTICS_FILE` is unset, this is a no-op.
  """
  @spec maybe_write_diagnostics(String.t(), pos_integer()) :: :ok
  def maybe_write_diagnostics(output, invocation_index \\ 1) do
    case System.get_env("DIAGNOSTICS_FILE") do
      nil ->
        :ok

      filename ->
        expanded = String.replace(filename, "{N}", to_string(invocation_index))
        File.mkdir_p!(Path.dirname(expanded))
        File.write!(expanded, output)
    end
  end

  @doc """
  Finalizes the bench JSONL record for the given stack+test_name by flipping
  `assertion_passed` to `true` in the last `harness_summary` line.

  Call this AFTER the last ExUnit assertion in a test that uses
  `run_codegen_build/3` or `run_mode_launcher/4`. The record is written with
  `assertion_passed: false` (write-pending) at build time; this function flips
  it to `true` only when all assertions have passed.

  When `BENCH_RUN_DIR` is unset, this is a no-op.
  """
  @spec bench_assertions_passed!(String.t(), String.t()) :: :ok
  def bench_assertions_passed!(stack, test_name) do
    bench_run_dir = System.get_env("BENCH_RUN_DIR", "")

    if bench_run_dir == "" do
      :ok
    else
      harness_val = harness()
      path = bench_jsonl_path(bench_run_dir, harness_val, stack, test_name)

      if File.exists?(path) do
        content = File.read!(path)
        lines = String.split(content, "\n", trim: true)

        idx =
          lines
          |> Enum.with_index()
          |> Enum.filter(fn {line, _} ->
            case Jason.decode(line) do
              {:ok, %{"type" => "harness_summary"}} -> true
              _ -> false
            end
          end)
          |> List.last()

        case idx do
          {line, i} ->
            {:ok, decoded} = Jason.decode(line)
            updated = Jason.encode!(Map.put(decoded, "assertion_passed", true))
            new_lines = List.replace_at(lines, i, updated)
            File.write!(path, Enum.join(new_lines, "\n") <> "\n")

          nil ->
            IO.warn("bench_assertions_passed!: no harness_summary found in #{path}")
        end
      else
        IO.warn("bench_assertions_passed!: no JSONL found at #{path} — test_name mismatch?")
      end
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp bench_jsonl_path(bench_run_dir, harness_val, stack, test_name) do
    Path.join([bench_run_dir, "runs", harness_val, stack, "#{test_name}.jsonl"])
  end

  defp maybe_write_bench_record(
         output,
         exit_code,
         harness_val,
         stack,
         test_name,
         build_duration_ms
       ) do
    bench_run_dir = System.get_env("BENCH_RUN_DIR")

    if is_nil(bench_run_dir) or String.trim(bench_run_dir) == "" do
      :ok
    else
      harness_atom =
        case harness_val do
          "claude" -> :claude
          other -> String.to_atom(other)
        end

      parsed =
        output
        |> UsageParser.parse(harness_atom)
        |> Map.put(:build_duration_ms, build_duration_ms)

      per_role = UsageParser.parse_per_role(output, harness_atom)

      jsonl_dir = Path.join([bench_run_dir, "runs", harness_val, stack])
      File.mkdir_p!(jsonl_dir)
      jsonl_path = bench_jsonl_path(bench_run_dir, harness_val, stack, test_name)

      raw_lines =
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(fn line ->
          case Jason.decode(line) do
            {:ok, _} -> true
            _ -> false
          end
        end)
        |> Enum.join("\n")

      parsed_serializable =
        Map.new(parsed, fn
          {k, :unknown} -> {k, ":unknown"}
          {k, v} -> {k, v}
        end)

      summary = %{
        "type" => "harness_summary",
        "test_name" => test_name,
        "exit_code" => exit_code,
        "assertion_passed" => false,
        "parsed" => parsed_serializable,
        "per_role" => per_role
      }

      summary_line = Jason.encode!(summary)
      content = if raw_lines == "", do: summary_line, else: raw_lines <> "\n" <> summary_line
      File.write!(jsonl_path, content)

      resolved_model =
        case parsed.model do
          :unknown -> "unknown"
          model -> model
        end

      BenchManifest.record_resolution(
        bench_run_dir,
        harness_val,
        # role defaults to "app_build" — all 12 test call sites use this role;
        # update here and add a role: opt to run_codegen_build/3 if a new role is needed
        "app_build",
        resolved_model
      )
    end
  end

  defp maybe_write_mode_bench_record(
         output,
         exit_code,
         harness_val,
         stack,
         test_name,
         build_duration_ms
       ) do
    bench_run_dir = System.get_env("BENCH_RUN_DIR")

    if is_nil(bench_run_dir) or String.trim(bench_run_dir) == "" do
      :ok
    else
      harness_atom =
        case harness_val do
          "claude" -> :claude
          other -> String.to_atom(other)
        end

      parsed =
        output
        |> UsageParser.parse(harness_atom)
        |> Map.put(:build_duration_ms, build_duration_ms)

      jsonl_dir = Path.join([bench_run_dir, "runs", harness_val, stack])
      File.mkdir_p!(jsonl_dir)
      jsonl_path = bench_jsonl_path(bench_run_dir, harness_val, stack, test_name)

      parsed_serializable =
        Map.new(parsed, fn
          {k, :unknown} -> {k, ":unknown"}
          {k, v} -> {k, v}
        end)

      summary = %{
        "type" => "harness_summary",
        "test_name" => test_name,
        "exit_code" => exit_code,
        "assertion_passed" => false,
        "parsed" => parsed_serializable
      }

      File.write!(jsonl_path, Jason.encode!(summary))
    end
  end

  defp maybe_capture_screenshot(cwd, stack, test_name) do
    bench_run_dir = System.get_env("BENCH_RUN_DIR")

    if is_nil(bench_run_dir) or String.trim(bench_run_dir) == "" do
      :ok
    else
      BenchArtifacts.capture_screenshot(cwd, stack, bench_run_dir, test_name)
    end
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "harness"},
      {"GIT_AUTHOR_EMAIL", "harness@test"},
      {"GIT_COMMITTER_NAME", "harness"},
      {"GIT_COMMITTER_EMAIL", "harness@test"}
    ]
  end

  defp commit_fixture_baseline!(path, message) do
    ensure_git_repo!(path)

    {_add_out, 0} =
      System.cmd("git", ["add", "-A"], cd: path, env: git_env(), stderr_to_stdout: true)

    {status, 0} =
      System.cmd("git", ["status", "--porcelain"], cd: path, env: [], stderr_to_stdout: true)

    if String.trim(status) != "" do
      {_commit_out, 0} =
        System.cmd("git", ["commit", "--allow-empty", "-m", message],
          cd: path,
          env: git_env(),
          stderr_to_stdout: true
        )
    end

    :ok
  end

  defp ensure_git_repo!(path) do
    unless File.dir?(Path.join(path, ".git")) do
      {_init_out, 0} = System.cmd("git", ["init"], cd: path, env: [], stderr_to_stdout: true)
    end

    {_, 0} =
      System.cmd("git", ["config", "user.name", "harness"], cd: path, stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["config", "user.email", "harness@test"],
        cd: path,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd("git", ["config", "commit.gpgsign", "false"], cd: path, stderr_to_stdout: true)

    :ok
  end

  defp scaffold_phoenix_app!(parent_path) do
    unless File.exists?(@codegen_scaffold) do
      raise "codegen-scaffold not found at #{@codegen_scaffold}"
    end

    {output, exit_code} =
      System.cmd(
        @codegen_scaffold,
        ["create", "--stack=phoenix", "--cwd=#{parent_path}", "--slug=codegen_app"],
        stderr_to_stdout: true
      )

    if exit_code != 0 do
      raise "codegen-scaffold create failed (exit=#{exit_code}):\n#{output}"
    end

    Path.join(parent_path, "codegen_app")
  end

  defp run_with_timeout(cmd, args, _opts, timeout_ms) do
    # Redirect stdin from /dev/null to prevent subprocess blocking on stdin read
    shell_cmd =
      "env -u CODEGEN_DIR -u OCG_CODEGEN_DIR " <>
        Enum.map_join([cmd | args], " ", fn arg ->
          "'" <> String.replace(arg, "'", "'\\''") <> "'"
        end)

    port =
      Port.open(
        {:spawn, shell_cmd <> " </dev/null"},
        [:binary, :exit_status]
      )

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_port_output(port, [], deadline)
  end

  defp collect_port_output(port, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      do_timeout(port, acc, deadline)
    else
      receive do
        {^port, {:data, chunk}} ->
          collect_port_output(port, [chunk | acc], deadline)

        {^port, {:exit_status, code}} ->
          {IO.iodata_to_binary(Enum.reverse(acc)), code}

        {^port, :closed} ->
          collect_port_output(port, acc, deadline)
      after
        remaining ->
          do_timeout(port, acc, deadline)
      end
    end
  end

  defp do_timeout(port, acc, _deadline) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true)
        System.cmd("pkill", ["-9", "-P", "#{os_pid}"], stderr_to_stdout: true)

      _ ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :already_closed
    end

    # Write whatever output we have so far to diagnostics before raising
    partial_output = IO.iodata_to_binary(Enum.reverse(acc))
    maybe_write_diagnostics(partial_output, Process.get(:codegen_build_invocation, 1))

    timeout_minutes = div(5_400_000, 60_000)
    raise "codegen-build timed out after #{timeout_minutes} minutes"
  end

  @doc """
  Returns the number of commits in the git history of `cwd`.

  Raises if `git log` exits non-zero.
  """
  @spec count_commits!(String.t()) :: non_neg_integer()
  def count_commits!(cwd) do
    {log, 0} =
      System.cmd("git", ["log", "--oneline"], cd: cwd, stderr_to_stdout: true, env: [])

    log
    |> String.split("\n", trim: true)
    |> length()
  end

  # Resilient recursive delete for `isolated_tmp_dir/1` teardown.
  #
  # A Phoenix dev server spawned during render-check (`--spawn`) is
  # group-killed by `stopPhoenixServer` before `System.cmd` returns, but its
  # tailwind/esbuild watcher can flush a handful of files into the tmp tree in
  # the brief window after the kill signal and before the process actually
  # exits. That race can make `File.rm_rf!/1` observe a path that reappears
  # mid-delete and raise `EEXIST`, failing an otherwise-green test in
  # `on_exit`.
  #
  # This helper retries the non-bang `File.rm_rf/1` a few times with a short
  # sleep to let the last flush settle, then gives up quietly (with a visible
  # stderr note) rather than raising. `/tmp` is reaped by the OS regardless,
  # and the directory holds only scratch build output — a stuck cleanup here
  # must never fail a passing test, but a genuinely stuck cleanup should still
  # be observable via stderr.
  @rm_rf_retry_attempts 5
  @rm_rf_retry_sleep_ms 200

  # Exposed as `@doc false` (public but undocumented) rather than `defp` so
  # `CodegenTestHarness.FixturesTest` can exercise the retry/give-up paths
  # directly, mirroring the `@doc false` test-seam pattern already used by
  # `LoopGate`/`LoopQueueDrain`/`OrchestrationLoop`.
  @doc false
  @spec rm_rf_resilient(String.t()) :: :ok
  def rm_rf_resilient(path) do
    do_rm_rf_resilient(path, @rm_rf_retry_attempts)
  end

  defp do_rm_rf_resilient(path, attempts_left) do
    case File.rm_rf(path) do
      {:ok, _files} ->
        :ok

      {:error, _reason, _file} when attempts_left > 1 ->
        Process.sleep(@rm_rf_retry_sleep_ms)
        do_rm_rf_resilient(path, attempts_left - 1)

      {:error, reason, file} ->
        IO.puts(
          :stderr,
          "rm_rf_resilient: giving up cleaning up #{path} after #{@rm_rf_retry_attempts} attempts " <>
            "(last error: #{inspect(reason)} on #{inspect(file)}) — leaving for OS tmp reaping"
        )

        :ok
    end
  end
end
