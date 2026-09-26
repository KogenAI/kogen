defmodule Kogen.IntegrityFixture do
  @moduledoc false

  # A disposable real Git repository holding a tiny ExUnit Mix project, with
  # an admission catalog carrying the integrity fields
  # (`verification_surface`, `focused_runner`, `base_cache`). Used to drive
  # `Kogen.Build.Verification.run_cycle/4`, `Kogen.Build.ProofSelectors`,
  # `Kogen.Build.Ledger` and `Kogen.Build.BaseWorkspace` against real Git
  # trees and a real `mix test` run, without going through the full
  # provider-harness Build.

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Kogen.Build.BaseWorkspace
  alias Kogen.Build.Verification
  alias Kogen.Build.VerificationPlan

  @git_env [
    {"GIT_AUTHOR_NAME", "Kogen Integrity Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-integrity-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Integrity Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-integrity-fixture@example.invalid"}
  ]

  @doc """
  Creates the fixture repository, commits the admission state and returns
  `%{dir: dir, base_commit: sha}`. `opts[:base_cache]` overrides the catalog's
  `base_cache` list (default `[]`).
  """
  def create(opts \\ []) do
    # Each isolated test runs in its own fresh OS process, so
    # `System.unique_integer/1` restarts from a small counter in every one;
    # two concurrent isolated tests could otherwise pick the same directory.
    unique = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    dir = Path.join(System.tmp_dir!(), "kogen-integrity-fixture-#{System.pid()}-#{unique}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    write!(dir, "mix.exs", mix_exs())
    write!(dir, "lib/calc.ex", calc_lib())
    write!(dir, "test/test_helper.exs", "ExUnit.start(exclude: [:live])\n")
    write!(dir, "priv/value.txt", "base\n")
    write!(dir, "Makefile", makefile())
    write!(dir, "priv/kogen/verification_targets.yaml", catalog_yaml(opts))
    write!(dir, ".gitignore", "_build/\n.kogen/\n.DS_Store\n")

    # Build admission copies control deps/ into each Candidate.

    File.mkdir_p!(Path.join(dir, "deps"))

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "admission"])
    base_commit = head!(dir)
    avoid_racy_git_mtime()

    %{dir: dir, base_commit: base_commit}
  end

  @doc "Writes `relative` under `dir` with `content`, creating parent directories."
  def write!(dir, relative, content) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  @doc "Removes `relative` under `dir`."
  def remove!(dir, relative), do: File.rm(Path.join(dir, relative))

  @doc "The current `HEAD` commit sha of `dir`."
  def head!(dir) do
    {out, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir, env: @git_env)
    String.trim(out)
  end

  @doc "Commits every change in `dir`'s working tree and returns the new HEAD sha."
  def commit!(dir, message) do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", message])
    sha = head!(dir)
    avoid_racy_git_mtime()
    sha
  end

  # Git's stat-cache optimization can reuse a path's cached blob sha when its
  # mtime does not clearly postdate the index entry it is compared against
  # (the well-known "racy git" problem), which briefly races a test that
  # immediately overwrites a path it just committed. This sleeps past a
  # filesystem's mtime granularity so every subsequent edit's mtime is
  # unambiguously newer.
  defp avoid_racy_git_mtime, do: Process.sleep(1_100)

  @doc "The write-tree Candidate id of `dir`'s current working tree (uncommitted included)."
  def candidate_id!(dir) do
    File.cd!(dir, fn ->
      case Kogen.Git.candidate_id() do
        {:ok, id} -> id
        {:error, reason} -> raise "could not derive Candidate id: #{reason}"
      end
    end)
  end

  @scrubbed_mix_vars ~w(MIX_BUILD_PATH MIX_ENV MIX_EXS)

  @doc """
  Runs `Kogen.Build.Verification.run_cycle/4` with `dir` as the process's
  current directory for the whole call (`Kogen.Git.candidate_id/0`, used
  internally to re-check the Candidate after each target, has no root
  parameter and always reads the process's cwd). Returns
  `{candidate_id, run_cycle_result}`.

  The controller's own verification children inherit the calling process's
  environment; `Kogen.IsolatedCase` sets its own `MIX_BUILD_PATH` for this
  isolated test VM, which would otherwise leak into the fixture's nested
  `mix` invocations (and any `MIX_ENV`/`MIX_EXS` an outer harness carries),
  so this scrubs them for the duration of the call the same way a real
  top-level `mix kogen.build` invocation would never have them set.
  """
  def run_cycle!(dir, execution, session_id, env) do
    previous = Map.new(@scrubbed_mix_vars, &{&1, System.get_env(&1)})
    Enum.each(@scrubbed_mix_vars, &System.delete_env/1)

    try do
      File.cd!(dir, fn ->
        {:ok, candidate_id} = Kogen.Git.candidate_id()

        {candidate_id, Verification.run_cycle(execution, session_id, candidate_id, env)}
      end)
    after
      Enum.each(previous, fn
        {_key, nil} -> :ok
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  @doc """
  Builds the `env` map `Kogen.Build.Verification.run_cycle/4` and
  `Kogen.Build.ProofSelectors` expect: `:root`, `:catalog`, `:plan`,
  `:scenarios`, `:base_commit` and `:workspace`.
  """
  def env(dir, scenarios, opts \\ []) do
    {:ok, catalog} = VerificationPlan.load(dir)
    guards = Keyword.get(opts, :guards, ["**"])
    added = Keyword.get(opts, :added, [])

    {:ok, plan} = VerificationPlan.build(scenarios, guards, catalog, dir, added: added)
    base_commit = Keyword.get(opts, :base_commit, head!(dir))

    workspace =
      case Keyword.fetch(opts, :workspace) do
        {:ok, value} -> value
        :error -> build_workspace(dir, base_commit, catalog)
      end

    %{
      root: dir,
      catalog: catalog,
      plan: plan,
      scenarios: scenarios,
      base_commit: base_commit,
      workspace: workspace
    }
  end

  @doc """
  A scenario map ready for `VerificationPlan.build/5`. `opts[:base]` is
  `"fail"`, `"pass"` or `nil`. `opts[:offline]` is the list of proof
  selectors (defaults to `opts[:file]` wrapped in a list).
  """
  def scenario(id, file, opts \\ []) do
    %{
      "id" => id,
      "given" => "given",
      "when" => "when",
      "then" => "then",
      "wrong_result" => "wrong",
      "verified_by" => Keyword.get(opts, :verified_by, ["check"]),
      "evidence" => "fixture",
      "proof" => %{
        "offline" => Keyword.get(opts, :offline, [file]),
        "paid_target" => "none",
        "paid_reason" => "offline-sufficient: fixture",
        "affected_paths" => Keyword.get(opts, :affected_paths, ["lib/**"]),
        "base" => Keyword.get(opts, :base)
      }
    }
  end

  @doc """
  Initializes a fresh `Kogen.Build.Verification` execution under `dir` for
  one attempt, ready for `run_cycle/4`.
  """
  def execution!(
        dir,
        token \\ "attempt-token",
        outer_attempt \\ 1,
        targets \\ ["check"],
        plan \\ nil
      ) do
    tracking_path =
      Path.join(dir, ".kogen/runtime/scenario-tracking/build-x/record.json")

    {:ok, execution} =
      Verification.initialize(tracking_path, token, outer_attempt, targets, 2, plan)

    execution
  end

  defp build_workspace(dir, base_commit, catalog) do
    if catalog.integrity do
      {:ok, workspace} =
        BaseWorkspace.create(dir, base_commit, catalog.integrity["base_cache"])

      on_exit(fn -> BaseWorkspace.remove(workspace) end)
      workspace
    end
  end

  defp git!(dir, args) do
    {_out, 0} = System.cmd("git", args, cd: dir, env: @git_env, stderr_to_stdout: true)
  end

  defp mix_exs do
    """
    defmodule Fixture.MixProject do
      use Mix.Project

      def project do
        [app: :fixture, version: "0.1.0", elixir: "~> 1.14", deps: []]
      end

      def application, do: [extra_applications: [:logger]]
    end
    """
  end

  defp calc_lib do
    """
    defmodule Calc do
      def add(a, b), do: a + b

      def value do
        Path.join(Path.dirname(__DIR__), "priv/value.txt")
        |> File.read!()
        |> String.trim()
      end
    end
    """
  end

  defp makefile do
    """
    .PHONY: check

    check:
    \tmix compile --warnings-as-errors
    """
  end

  defp catalog_yaml(opts) do
    base_cache = Keyword.get(opts, :base_cache, [])

    base_cache_yaml =
      if base_cache == [], do: "[]", else: "\n" <> Enum.map_join(base_cache, "\n", &"    - #{&1}")

    """
    targets:
      - name: check
        cost_class: offline-complete
        rank: 0
        dependencies: []
        provider_backed: false
        owner: fixture

    verification_surface:
      tests: ["test/*_test.exs", "test/**/*_test.exs"]
      runner: ["mix.exs", "test/test_helper.exs", "Makefile"]
    focused_runner: ["mix", "test", "--exclude", "live", "{paths}"]
    base_cache: #{base_cache_yaml}
    """
  end
end
