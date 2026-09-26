defmodule Kogen.WorkspaceFixture do
  @moduledoc """
  A disposable control checkout for Candidate Build tests: a real Git
  repository with Kogen's tracked hook files and prompts, a fixture `check`
  that fails while the Candidate's ignored `.kogen/runtime/kogen_fake_break`
  exists, a Codex route, a control `deps/` (and a `_build/` that must never be
  copied), and one Approved Intent guarding `dummy.txt`.

  Builds run in-process through `Kogen.Build.run/3` with an explicit control
  root, from a third working directory, so nothing can pass by working in
  the invoking checkout.
  """

  alias Kogen.Build.Workspace

  @slug "workspace-fixture"
  @intent_id "01a0c467-0000-7000-8000-00000000f1c5"

  @config """
  default_route: codex
  routes:
    codex:
      harness: codex
      shaping:   {model: fake, effort: low}
      developer: {model: fake, effort: low}
      reviewer:  {model: fake, effort: low}
      helpers:
        scout:  {model: fake, effort: low}
        worker: {model: fake, effort: medium}
        expert: {model: fake, effort: medium}
  outer_resumptions: 2
  verification_retries: 2
  """

  @claude_config """
  default_route: claude
  routes:
    claude:
      harness: claude
      shaping:   {model: claude-opus-5-5, effort: medium}
      developer: {model: claude-opus-5-5, effort: medium}
      reviewer:  {model: claude-opus-5-5, effort: medium}
      helpers:
        scout:  {model: claude-sonnet-5, effort: low}
        worker: {model: claude-sonnet-5, effort: medium}
        expert: {model: claude-opus-5-5, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  @hybrid_config """
  default_route: hybrid
  routes:
    hybrid:
      shaping:   {harness: claude, model: claude-opus-5-5, effort: medium}
      developer: {harness: claude, model: claude-opus-5-5, effort: medium}
      reviewer:  {harness: codex, model: gpt-6-sol, effort: high}
      expert:    {harness: codex, model: gpt-6-sol, effort: high}
      helpers:
        claude:
          scout:  {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
        codex:
          scout:  {model: gpt-6-luna, effort: low}
          worker: {model: gpt-6-luna, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  @makefile """
  .PHONY: check
  check:
  \t@test ! -f .kogen/runtime/kogen_fake_break || { echo 'fixture check: kogen_fake_break remains' >&2; exit 1; }
  """

  @gitignore """
  .kogen/build.lock
  .kogen/runtime/
  .kogen/codex/
  .kogen/intents/drafts/
  .kogen/intents/approved/
  .codex/sessions/
  deps/
  _build/
  """

  def slug, do: @slug

  @doc """
  True in a `Kogen.IsolatedCase` child VM. That case's `setup` callbacks also
  run in the parent VM, where a Build's environment and working-directory
  changes would leak into concurrently running tests; fixture setups that run
  a Build do so only in the child, which is where the test body runs.
  """
  def isolated_child?, do: System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1"
  def intent_id, do: @intent_id

  @doc "The Kogen checkout the tests run from."
  def project_root, do: System.get_env("KOGEN_TEST_ROOT") || File.cwd!()

  @doc "A unique disposable directory (canonical once created)."
  def tmp_dir!(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "kogen-#{label}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    Workspace.canonical(path)
  end

  @doc "Creates the control checkout; options: `:guards`, `:scenarios`, `:deps`."
  def create!(opts \\ []) do
    control = tmp_dir!("workspace-control")
    source = project_root()

    for relative <- [
          ".codex/hooks.json",
          ".codex/hooks/check.sh",
          ".codex/hooks/stop_runner.py",
          ".codex/hooks/environment.py",
          ".codex/hooks/verification_policy.py",
          "priv/kogen/prompts/developer.md",
          "priv/kogen/prompts/reviewer.md",
          "priv/kogen/prompts/execution-policy.md",
          "priv/kogen/prompts/expert.md"
        ] do
      destination = Path.join(control, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.join(source, relative), destination)
    end

    File.chmod!(Path.join(control, ".codex/hooks/check.sh"), 0o755)
    File.write!(Path.join(control, "Makefile"), @makefile)
    File.write!(Path.join(control, ".gitignore"), @gitignore)
    File.write!(Path.join(control, "dummy.txt"), "baseline\n")
    File.write!(Path.join(control, "README.md"), "control sentinel\n")
    File.mkdir_p!(Path.join(control, ".kogen"))

    config =
      case Keyword.get(opts, :route) do
        :claude -> @claude_config
        :hybrid -> @hybrid_config
        _ -> @config
      end

    File.write!(Path.join(control, ".kogen/config.yaml"), config)

    if Keyword.get(opts, :deps, true) do
      File.mkdir_p!(Path.join(control, "deps/fixture_dep"))
      File.write!(Path.join(control, "deps/fixture_dep/mix.exs"), "# fixture dependency\n")
    end

    File.mkdir_p!(Path.join(control, "_build/test/lib/fixture"))
    File.write!(Path.join(control, "_build/test/lib/fixture/marker"), "control build\n")

    write_intent!(control, @slug, opts)
    git!(control, ["init", "-q", "-b", "main"])
    git!(control, ["add", "-A"])
    git!(control, ["commit", "-q", "-m", "fixture baseline"])
    control
  end

  @doc "Writes an Approved Intent `slug` into control's ignored approved directory."
  def write_intent!(control, slug, opts \\ []) do
    guards = Keyword.get(opts, :guards, ["dummy.txt"])

    intent = """
    id: #{Keyword.get(opts, :intent_id, @intent_id)}
    slug: #{slug}
    title: Workspace fixture #{slug}
    may_change_guarded_paths:
    #{Enum.map_join(guards, "\n", &"  - #{&1}")}
    """

    scenarios =
      Keyword.get(opts, :scenarios, """
      - id: fixture-scenario
        given: a fixture Candidate
        when: the fake roles run
        then: the controller verifies and publishes in the Candidate
        wrong_result: the Build works in the control checkout
        verified_by: [check]
        evidence: fixture only
      """)

    directory = Path.join(control, ".kogen/intents/approved/#{slug}")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "intent.yaml"), intent)
    File.write!(Path.join(directory, "scenarios.yaml"), scenarios)
    Kogen.VerificationFixture.install!(control)
    directory
  end

  @doc "Writes an executable fake role script `name` under `dir` and returns its path."
  def fake!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  @doc "The fixture's support scripts directory in the Kogen checkout."
  def support(name), do: Path.join([project_root(), "test/support", name])

  @doc """
  Runs one Build of `slug` for `control` in-process from a third cwd, with
  `env` (`{name, value | nil}`) applied for the call and restored after.
  """
  def build!(control, opts \\ []) do
    slug = Keyword.get(opts, :slug, @slug)
    third = Keyword.get_lazy(opts, :cwd, fn -> tmp_dir!("third-cwd") end)

    env =
      [
        {"KOGEN_HARNESS", Keyword.get(opts, :harness, support("fake_codex_simple_accept"))},
        {"KOGEN_JEV_TRANSPORT", support("fake_jev")},
        {"KOGEN_JEV_SECURITY", support("fake_security")},
        {"FAKE_JEV_LOG_DIR", Path.join(tmp_dir!("fake-jev"), "log")},
        # A caller's KOGEN_LIVE_LOG_DIR (the outer controller's, when this
        # suite runs as a controller-run `check`) never reaches a fixture
        # Build; a test that passes its own in `:env` still wins.
        {"KOGEN_LIVE_LOG_DIR", nil}
      ] ++ git_identity() ++ Keyword.get(opts, :env, [])

    with_env(env, fn ->
      File.cd!(third, fn -> Kogen.Build.run(slug, Keyword.get(opts, :route), control) end)
    end)
  end

  @doc "Applies `env` for the duration of `fun`, restoring every previous value."
  def with_env(env, fun) do
    previous = Enum.map(env, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(env, &put_env/1)

    try do
      fun.()
    after
      Enum.each(previous, &put_env/1)
    end
  end

  defp put_env({name, nil}), do: System.delete_env(name)
  defp put_env({name, value}), do: System.put_env(name, value)

  def git_identity do
    [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]
  end

  def git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: git_identity()) do
      {out, 0} -> String.trim(out)
      {out, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{out}"
    end
  end

  def git(dir, args) do
    System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: git_identity())
  end

  @doc "`git status --porcelain`, HEAD, index bytes and every tracked file's bytes."
  def control_state(control) do
    files = control |> git!(["ls-files", "-z"]) |> String.split(<<0>>, trim: true)

    %{
      head: git!(control, ["rev-parse", "HEAD"]),
      branch: git!(control, ["symbolic-ref", "--short", "HEAD"]),
      status: git!(control, ["status", "--porcelain"]),
      index: File.read!(Path.join(control, ".git/index")),
      tracked: Map.new(files, &{&1, File.read!(Path.join(control, &1))})
    }
  end

  @doc "The project directory of `control` under the current workspaces root."
  def project_dir(control), do: Workspace.project_dir(control)

  @doc """
  A disposable managed Claude Code root with an existing shared login scope,
  for `KOGEN_CLAUDE_ROOT`; the fake `claude` answers `auth status` itself.
  """
  def claude_root! do
    root = tmp_dir!("claude-root")
    File.mkdir_p!(Path.join(root, "accounts/shared"))
    root
  end

  @doc """
  A wrapper role that, on the fresh Developer launch only, signals
  `<harness home>/waiting` from inside the launched process and waits for the
  test process to write `<harness home>/go`, then runs `next`.
  """
  def waiting_role!(dir, next) do
    fake!(dir, "waiting_role", """
    #!/bin/sh
    if [ "${KOGEN_ROLE:-}" = developer ] && [ ! -f "$KOGEN_HARNESS_HOME/released" ]; then
      is_resume=0
      for a in "$@"; do [ "$a" = --resume ] && is_resume=1; [ "$a" = resume ] && is_resume=1; done
      if [ "$is_resume" = 0 ]; then
        : > "$KOGEN_HARNESS_HOME/waiting"
        i=0
        while [ ! -f "$KOGEN_HARNESS_HOME/go" ] && [ "$i" -lt 1200 ]; do sleep 0.05; i=$((i + 1)); done
        : > "$KOGEN_HARNESS_HOME/released"
        if [ -n "${FIXTURE_DEV_EDIT:-}" ]; then sh -c "$FIXTURE_DEV_EDIT"; fi
      fi
    fi
    exec #{inspect(next)} "$@"
    """)
  end

  @doc "Waits for a fixture Build's waiting role and returns its harness home."
  def await_waiting!(control, attempts \\ 1200) do
    case Path.wildcard(Path.join(project_dir(control), "harness/*/waiting")) do
      [waiting] ->
        Path.dirname(waiting)

      [] when attempts > 0 ->
        Process.sleep(50)
        await_waiting!(control, attempts - 1)

      other ->
        raise "fixture Build never reached its waiting role: #{inspect(other)}"
    end
  end

  @doc "Every owner record of `control`."
  def owner_records(control) do
    control
    |> project_dir()
    |> Path.join("candidates/*.json")
    |> Path.wildcard()
    |> Enum.map(&(File.read!(&1) |> Jason.decode!()))
  end
end
