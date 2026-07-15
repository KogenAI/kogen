defmodule CodegenTestHarness.Assertions do
  @moduledoc """
  Filesystem and process assertions for stack scaffold tests.
  """

  import ExUnit.Assertions

  def assert_mix_compiles!(cwd) do
    {deps_out, deps_code} =
      System.cmd("mix", ["deps.get"], cd: cwd, stderr_to_stdout: true)

    assert deps_code == 0, "mix deps.get failed in #{cwd}:\n#{deps_out}"

    {output, exit_code} = System.cmd("mix", ["compile"], cd: cwd, stderr_to_stdout: true)
    assert exit_code == 0, "mix compile failed in #{cwd}:\n#{output}"
    :ok
  end

  @doc """
  Asserts `git log -1` succeeds and the commit subject is non-empty.

  Returns `:ok`.
  """
  @spec assert_commit_well_formed!(String.t()) :: :ok
  def assert_commit_well_formed!(cwd) do
    {subject, exit_code} =
      System.cmd("git", ["log", "-1", "--format=%s"], cd: cwd, stderr_to_stdout: true, env: [])

    assert exit_code == 0, "git log -1 failed in #{cwd} (exit #{exit_code})"

    commit_msg = String.trim(subject)
    assert commit_msg != "", "Commit subject must not be empty in #{cwd}"

    {body, 0} =
      System.cmd("git", ["log", "-1", "--format=%B"], cd: cwd, stderr_to_stdout: true, env: [])

    refute String.contains?(body, "Co-Authored-By"),
           "Commit must not contain Co-Authored-By trailer in #{cwd}"

    :ok
  end

  @doc """
  Asserts the most recent git commit subject in `cwd` is at most `max` bytes.

  Revert commits (`Revert "..."`) are skipped.

  Returns `:ok`.
  """
  @spec assert_commit_subject_length!(String.t(), non_neg_integer()) :: :ok
  def assert_commit_subject_length!(cwd, max \\ 72) do
    {subject, 0} =
      System.cmd("git", ["log", "-1", "--format=%s"], cd: cwd, stderr_to_stdout: true, env: [])

    commit_msg = String.trim(subject)

    unless String.starts_with?(commit_msg, "Revert \"") do
      assert String.length(commit_msg) <= max,
             "Commit subject must be ≤#{max} chars, got #{String.length(commit_msg)}: #{inspect(commit_msg)}"
    end

    :ok
  end

  @doc """
  Asserts that the commit count in `cwd` increased compared to `commits_before`.

  Returns `:ok`.
  """
  @spec assert_new_commit_since!(String.t(), non_neg_integer()) :: :ok
  def assert_new_commit_since!(cwd, commits_before) do
    {log, 0} =
      System.cmd("git", ["log", "--oneline"], cd: cwd, stderr_to_stdout: true, env: [])

    commits_after =
      log
      |> String.split("\n", trim: true)
      |> length()

    assert commits_after > commits_before,
           "Expected new commit after change request. " <>
             "Before: #{commits_before}, after: #{commits_after} in #{cwd}"

    :ok
  end

  @doc """
  Asserts HEAD commit subject does not start with `Revert "`.

  Returns `:ok`.
  """
  @spec assert_not_revert_head!(String.t()) :: :ok
  def assert_not_revert_head!(cwd) do
    {subject, 0} =
      System.cmd("git", ["log", "-1", "--format=%s"], cd: cwd, stderr_to_stdout: true, env: [])

    commit_msg = String.trim(subject)

    refute String.starts_with?(commit_msg, "Revert \""),
           "HEAD must not be a revert commit in #{cwd}: #{inspect(commit_msg)}"

    :ok
  end

  def assert_npm_builds!(cwd) do
    package_json = Path.join(cwd, "package.json")

    if File.exists?(package_json) do
      {_install_out, install_code} =
        System.cmd("npm", ["install", "--silent", "--no-audit", "--no-fund"],
          cd: cwd,
          stderr_to_stdout: true
        )

      assert install_code == 0, "npm install failed in #{cwd}"

      json = File.read!(package_json)

      if String.contains?(json, ~s("build")) do
        {build_out, build_code} =
          System.cmd("npm", ["run", "build"], cd: cwd, stderr_to_stdout: true)

        assert build_code == 0, "npm run build failed in #{cwd}:\n#{build_out}"
      end
    end

    :ok
  end

  @doc """
  Asserts that `output` looks like a debug-mode diagnostic report:
  must contain both "Root Cause" and "Evidence" (case-insensitive).
  """
  def assert_diagnostic_report_shape!(output) when is_binary(output) do
    assert output =~ ~r/root cause/i,
           "debug output must contain 'Root Cause'. Got:\n#{output}"

    assert output =~ ~r/evidence/i,
           "debug output must contain 'Evidence'. Got:\n#{output}"
  end

  @doc """
  Asserts that `git status --porcelain` in `cwd` matches `before_porcelain` —
  i.e. no new files were written or modified since the baseline was captured.
  """
  def assert_no_files_written!(cwd, before_porcelain) do
    {after_porcelain, 0} =
      System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true, env: [])

    assert after_porcelain == before_porcelain,
           "debug mode must not write files.\n" <>
             "Before porcelain:\n#{before_porcelain}\n" <>
             "After porcelain:\n#{after_porcelain}"
  end

  def assert_file_contains!(path, needle) when is_binary(needle) do
    assert File.exists?(path), "expected file #{path} to exist"
    content = File.read!(path)

    assert String.contains?(content, needle),
           "expected #{path} to contain #{inspect(needle)}\n--- content ---\n#{content}"

    :ok
  end

  def assert_file_matches!(path, %Regex{} = pattern) do
    assert File.exists?(path), "expected file #{path} to exist"
    content = File.read!(path)

    assert content =~ pattern,
           "expected #{path} to match #{inspect(pattern)}\n--- content ---\n#{content}"

    :ok
  end

  def assert_git_committed!(cwd) do
    {log, exit_code} =
      System.cmd("git", ["log", "--oneline", "-1"], cd: cwd, stderr_to_stdout: true)

    assert exit_code == 0, "git log failed in #{cwd}:\n#{log}"
    assert String.trim(log) != "", "no git commit found in #{cwd}"
    :ok
  end

  @doc """
  Runs `mix test --max-failures 1` in `cwd` and asserts exit code is 0.

  Returns `:ok`.
  """
  @spec assert_generated_tests_pass!(String.t()) :: :ok
  def assert_generated_tests_pass!(cwd) do
    # Remove stale _build artifacts before running tests: the LLM agent may have
    # compiled the app in dev mode (baking compile_env values like code_reloader:
    # true). Running mix test with MIX_ENV=test after a dev compile triggers
    # "different value set during runtime compared to compile time" from Phoenix
    # Application.compile_env checks. Deleting _build forces a clean test-env
    # compile, eliminating the dev/test cross-contamination.
    File.rm_rf!(Path.join(cwd, "_build"))

    {out, code} =
      System.cmd("mix", ["test", "--max-failures", "1"],
        cd: cwd,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    assert code == 0, "generated app's own tests failed in #{cwd}:\n#{out}"
    :ok
  end

  @doc """
  Asserts the router at `router_path` has a `live "/"` route and does NOT
  still contain the default `get "/", PageController` route.

  Returns `:ok`.
  """
  @spec assert_router_root_route_replaced!(String.t()) :: :ok
  def assert_router_root_route_replaced!(router_path) do
    content = File.read!(router_path)
    assert content =~ ~r/live\s+"\/"/, "router missing live \"/\" route"

    refute content =~ ~r/get\s+"\/"\s*,\s*\w+Controller/,
           "default get \"/\" PageController route still present — generated app must REPLACE it, not add alongside (router serves blank default page)"

    :ok
  end

  @doc """
  Asserts the built HTML at `Path.join(cwd, rel)` exists and references a built
  bundle script (hashed `/assets/*.js` or similar) — proving Vite produced real
  output rather than an unbuilt shell. Visible-content rendering is proven
  separately by `assert_renders!/2` (headless Chromium).

  Returns `:ok`.
  """
  @spec assert_built_html_non_blank!(String.t(), String.t()) :: :ok
  def assert_built_html_non_blank!(cwd, rel \\ "public/index.html") do
    path = Path.join(cwd, rel)
    assert File.exists?(path), "expected #{rel} after build"
    html = File.read!(path)

    assert html =~ ~r/<script[^>]+src=["'][^"']*\.\w+\.(js|mjs)["']/i or
             html =~ ~r/<script[^>]+src=["']\/assets\/[^"']+["']/i,
           "#{rel} has no built bundle script — Vite did not produce hashed output (unbuilt shell?)"

    :ok
  end

  @doc """
  Asserts that rendering the app at `cwd` produces PASS or INCONCLUSIVE.
  INCONCLUSIVE is tolerated — browser or server may be absent in CI.
  FAIL causes a flunk.

  `mode` is `:phoenix` or `:static`.

  Returns `:ok`.
  """
  @spec assert_renders!(String.t(), :phoenix | :static) :: :ok
  def assert_renders!(cwd, mode) do
    case CodegenTestHarness.Fixtures.render_verdict(cwd, mode) do
      {:pass} ->
        :ok

      {:inconclusive, reason} ->
        IO.warn("render INCONCLUSIVE in #{cwd} (#{mode}): #{reason}")
        :ok

      {:fail, reason} ->
        flunk("render failed in #{cwd} (#{mode}): #{reason}")
    end
  end

  @doc """
  Bundles quality assertions for a build: compile + tests (Phoenix only) +
  render + committed.

  `opts`:
  - `:mode` — `:phoenix` or `:static` (required)

  Returns `:ok`.
  """
  @spec assert_build_quality!(String.t(), keyword()) :: :ok
  def assert_build_quality!(cwd, opts) do
    mode = Keyword.fetch!(opts, :mode)

    if File.exists?(Path.join(cwd, "mix.exs")) do
      assert_mix_compiles!(cwd)
      assert_generated_tests_pass!(cwd)
    end

    assert_renders!(cwd, mode)
    assert_git_committed!(cwd)
    :ok
  end

  @spec assert_assets_deploy!(String.t()) :: :ok
  def assert_assets_deploy!(cwd) do
    has_assets_dir = File.dir?(Path.join(cwd, "assets"))
    mix_exs_content = File.read!(Path.join(cwd, "mix.exs"))
    has_alias = String.contains?(mix_exs_content, ~s("assets.deploy"))

    if has_assets_dir and has_alias do
      {output, exit_code} =
        System.cmd("mix", ["assets.deploy"],
          cd: cwd,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "dev"}]
        )

      assert exit_code == 0, "mix assets.deploy failed in #{cwd}:\n#{output}"

      css = Path.join([cwd, "priv", "static", "assets", "css", "app.css"])
      assert File.exists?(css), "expected #{css} after mix assets.deploy"
      assert File.stat!(css).size > 0, "expected #{css} non-empty"

      js = Path.join([cwd, "priv", "static", "assets", "js", "app.js"])

      if File.exists?(js) do
        assert File.stat!(js).size > 0, "expected #{js} non-empty"
      end
    end

    :ok
  end

  @doc """
  Asserts that the shared usage_rules corpus INDEX (reached via the
  `codegen/usage_rules` symlink seeded by codegen-scaffold) cites no dangling
  files — every `- \`<file>.md\`` line under a `## <dep>` heading must resolve
  to a real file inside `codegen/usage_rules/`.

  Returns `:ok`.
  """
  @spec assert_usage_rules_index_no_dangling_citations!(String.t()) :: :ok
  def assert_usage_rules_index_no_dangling_citations!(cwd) do
    usage_rules_dir = Path.join(cwd, "codegen/usage_rules")
    index_path = Path.join(usage_rules_dir, "INDEX.md")

    assert File.exists?(index_path), "expected #{index_path} to exist"

    content = File.read!(index_path)

    cited_files =
      ~r/^- `([^`]+)`$/m
      |> Regex.scan(content)
      |> Enum.map(fn [_, filename] -> filename end)

    assert cited_files != [], "expected #{index_path} to cite at least one file"

    dangling =
      Enum.reject(cited_files, fn filename ->
        File.exists?(Path.join(usage_rules_dir, filename))
      end)

    assert dangling == [],
           "dangling citation(s) in #{index_path} — cited but missing from #{usage_rules_dir}: #{inspect(dangling)}"

    :ok
  end
end
