defmodule Kogen.ControllerBuildFixture do
  @moduledoc false

  # A minimal git fixture plus direct calls into the controller-owned
  # verification modules (`Kogen.Build.Verification`,
  # `Kogen.Build.VerificationPlan`, `Kogen.Build.VerificationRunner`),
  # without going through the full `Kogen.Build.run/1` harness protocol. Used
  # by `test/kogen/controller_verification_test.exs` for target-, receipt-
  # and settlement-level assertions that do not need a Developer/Reviewer
  # turn at all.

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Kogen.Build.{Verification, VerificationPlan}

  @git_env [
    {"GIT_AUTHOR_NAME", "Kogen Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
  ]

  @doc "Creates a disposable git repository with `files` (relative path => content)."
  def repo!(files) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-controller-fixture-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    Enum.each(files, fn {path, content} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "baseline"])
    dir
  end

  @doc "Stages and commits every current change in `dir`."
  def commit_all!(dir, message \\ "candidate change") do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", message])
  end

  @doc "The Candidate id (private-index write-tree) for the worktree at `dir`."
  def candidate_id!(dir) do
    File.cd!(dir, fn ->
      {:ok, id} = Kogen.Git.candidate_id()
      id
    end)
  end

  @doc "Loads and validates the verification-target catalog at `dir`."
  def load_catalog!(dir) do
    {:ok, catalog} = VerificationPlan.load(dir)
    catalog
  end

  @doc "Builds a plan for `scenarios` (already-decoded maps) against `catalog`."
  def build_plan!(dir, scenarios, catalog, opts \\ []) do
    {:ok, plan} =
      VerificationPlan.build(
        scenarios,
        Keyword.get(opts, :guards, []),
        catalog,
        dir,
        added: Keyword.get(opts, :added, [])
      )

    plan
  end

  @doc """
  Minimal scenario map selecting `targets` (`verified_by`), with a required
  offline proof selector so `VerificationPlan.build/5` accepts it.
  """
  def scenario(id, targets, opts \\ []) do
    %{
      "id" => id,
      "verified_by" => targets,
      "proof" => %{
        "offline" => Keyword.get(opts, :offline, []),
        "affected_paths" => Keyword.get(opts, :affected_paths, []),
        "paid_target" => Keyword.get(opts, :paid_target, "none"),
        "paid_reason" =>
          Keyword.get(opts, :paid_reason, "offline-sufficient: controller fixture scenario")
      }
    }
  end

  @doc "Initializes a controller verification execution for one outer attempt."
  def initialize!(dir, targets, opts \\ []) do
    build_id = Keyword.get(opts, :build_id, "build-#{System.unique_integer([:positive])}")
    tracking_path = Path.join(dir, ".kogen/runtime/scenario-tracking/#{build_id}/record.json")
    File.mkdir_p!(Path.dirname(tracking_path))

    token = Keyword.get(opts, :token, "tok-#{System.unique_integer([:positive])}")
    retries = Keyword.get(opts, :retries, 2)
    outer_attempt = Keyword.get(opts, :outer_attempt, 0)
    plan = Keyword.get(opts, :plan)

    {:ok, execution} =
      Verification.initialize(tracking_path, token, outer_attempt, targets, retries, plan)

    execution
  end

  @doc "The verification `env` map `Verification.run_cycle/4` expects."
  def env(dir, catalog, plan, scenarios, opts \\ []) do
    %{
      root: dir,
      catalog: catalog,
      plan: plan,
      scenarios: scenarios,
      base_commit: Keyword.get(opts, :base_commit),
      workspace: Keyword.get(opts, :workspace)
    }
  end

  @doc "Runs one cycle, returning `{execution, state}` (a failed cycle is not an error)."
  def run_cycle!(execution, session_id, candidate_id, env) do
    case Verification.run_cycle(execution, session_id, candidate_id, env) do
      {:ok, execution, state} -> {execution, state}
      {:error, reason} -> raise "run_cycle failed unexpectedly: #{inspect(reason)}"
    end
  end

  defp git!(dir, args) do
    {_output, 0} = System.cmd("git", args, cd: dir, env: @git_env)
  end
end
