defmodule CodegenTestHarness.Fixtures do
  @moduledoc """
  Shared fixtures and helpers for stack scaffold tests.

  `harness/0` returns the harness under test (`"claude"` by default, override
  with `HARNESS=pi`).

  `codegen_build_path/0` returns the absolute path to the `codegen-build`
  script in the OCG repo root.

  `isolated_tmp_dir/0` creates a git-initialised temp directory outside the
  OCG working tree, registers an `on_exit` cleanup, and returns the path.
  Use this instead of `@tag :tmp_dir` to prevent build agents from committing
  to OCG `main`.

  `run_codegen_build/3` centralises the `System.cmd` invocation: builds
  with `--harness`, `--stack`, `--non-interactive`, `--cwd`, and the given
  prompt; asserts exit 0; returns the output string.

  `change_request/4` runs two sequential `codegen-build` calls in `cwd`:
  the first scaffolds the app, the second applies the change request.
  Returns `{commits_before, commits_after}` where both are commit-count integers.

  """

  @codegen_build Path.expand("../../../codegen-build", __DIR__)
  @codegen_build_timeout_ms 1_200_000

  @commit_contract_suffix """


  IMPORTANT: After completing the work, you MUST commit ALL changes via the committer subagent before exiting. The test harness counts git commits to verify completion. The commit subject (first line) MUST be ≤72 characters. Use imperative mood (e.g., "Add", "Fix", "Update") with no trailing period.
  """

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
  @spec isolated_tmp_dir() :: String.t()
  def isolated_tmp_dir do
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

    File.write!(Path.join(path, "CLAUDE.md"), """
    # Project Root

    This is the project directory. Write ALL output files here using relative paths.

    NEVER use `cd /tmp` or absolute `/tmp/` paths for project output files.
    NEVER run `mix phx.new /tmp/<name>` — use `mix phx.new <name>` (relative) so the app lands under this directory.
    NEVER write HTML, Elixir, config, or any project file to an absolute path outside this directory.

    Use the Write tool with relative paths (e.g. `static/index.html`, `lib/my_app/foo.ex`).
    From Bash: create files relative to current directory, never `cat > /tmp/<file>`.

    For Phoenix apps: scaffold INTO the current directory using `echo "y" | mix phx.new . --app <name> --live` (e.g. `echo "y" | mix phx.new . --app hello_world --live`). The `echo "y"` is REQUIRED because the directory already exists and Phoenix will prompt for confirmation. NEVER use `mix phx.new <name>` — that creates a subdirectory instead of scaffolding here.
    """)

    {_init_out, 0} =
      System.cmd("git", ["init"], cd: path, env: [], stderr_to_stdout: true)

    {_, 0} = System.cmd("git", ["config", "user.name", "harness"], cd: path, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "harness@test"], cd: path, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: path, stderr_to_stdout: true)

    git_env = [
      {"GIT_AUTHOR_NAME", "harness"},
      {"GIT_AUTHOR_EMAIL", "harness@test"},
      {"GIT_COMMITTER_NAME", "harness"},
      {"GIT_COMMITTER_EMAIL", "harness@test"}
    ]

    {_commit_out, 0} =
      System.cmd(
        "git",
        ["commit", "--allow-empty", "-m", "init"],
        cd: path,
        env: git_env,
        stderr_to_stdout: true
      )

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)

    path
  end

  @doc "Returns the harness under test."
  @spec harness() :: String.t()
  def harness do
    System.get_env("HARNESS") || "claude"
  end

  @doc "Returns the absolute path to the `codegen-build` script."
  @spec codegen_build_path() :: String.t()
  def codegen_build_path do
    unless File.exists?(@codegen_build) do
      raise "codegen-build not found at #{@codegen_build}"
    end

    @codegen_build
  end

  @doc """
  Runs `codegen-build` with the given stack and prompt in `cwd`.

  Asserts exit 0 and returns the combined stdout+stderr output string.
  `opts` may include `stack:` (string, default `"phoenix"`) and any other
  keyword options (currently unused).
  """
  @spec run_codegen_build(String.t(), String.t(), keyword()) :: String.t()
  def run_codegen_build(cwd, prompt, opts \\ []) do
    harness_val = harness()
    stack = Keyword.get(opts, :stack, "phoenix")
    prompt_with_contract = prompt <> @commit_contract_suffix

    {output, exit_code} =
      run_with_timeout(
        codegen_build_path(),
        [
          "--harness=#{harness_val}",
          "--stack=#{stack}",
          "--non-interactive",
          "--cwd=#{cwd}",
          prompt_with_contract
        ],
        [],
        @codegen_build_timeout_ms
      )

    if exit_code != 0 do
      raise "codegen-build failed (harness=#{harness_val}, stack=#{stack}, exit=#{exit_code}):\n#{output}"
    end

    output
  end

  @doc """
  Runs two sequential `codegen-build` calls in `cwd`:
    1. `first_prompt` — scaffolds the app
    2. `second_prompt` — applies the change request

  Returns `{commits_before, commits_after}` where each value is the git commit
  count after the respective build.
  """
  @spec change_request(String.t(), String.t(), String.t(), keyword()) ::
          {non_neg_integer(), non_neg_integer()}
  def change_request(cwd, first_prompt, second_prompt, opts \\ []) do
    run_codegen_build(cwd, first_prompt, opts)
    commits_before = count_commits!(cwd)

    run_codegen_build(cwd, second_prompt, opts)
    commits_after = count_commits!(cwd)

    {commits_before, commits_after}
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp run_with_timeout(cmd, args, _opts, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, cmd},
        [:binary, :exit_status, args: args]
      )

    collect_port_output(port, [], timeout_ms)
  end

  defp collect_port_output(port, acc, timeout_ms) do
    receive do
      {^port, {:data, chunk}} ->
        collect_port_output(port, [chunk | acc], timeout_ms)

      {^port, {:exit_status, code}} ->
        {IO.iodata_to_binary(Enum.reverse(acc)), code}

      {^port, :closed} ->
        collect_port_output(port, acc, timeout_ms)
    after
      timeout_ms ->
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} ->
            System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true)

          _ ->
            :ok
        end

        Port.close(port)
        raise "codegen-build timed out after #{div(timeout_ms, 60_000)} minutes"
    end
  end

  defp count_commits!(cwd) do
    {log, 0} =
      System.cmd("git", ["log", "--oneline"], cd: cwd, stderr_to_stdout: true, env: [])

    log
    |> String.split("\n", trim: true)
    |> length()
  end
end
