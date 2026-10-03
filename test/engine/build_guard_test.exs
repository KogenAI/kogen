defmodule Kogen.Engine.BuildGuardTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project
  alias Kogen.Engine.Build.Guard
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Proc
  alias Kogen.Workspace

  test "rejects a changed protected file before checks run", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    protected_path = "checks.yml"
    original = "check: safe\n"
    File.write!(Path.join(repo, protected_path), original)
    git!(repo, ["add", protected_path])
    git!(repo, ["commit", "--quiet", "-m", "protect checks"])
    base_sha = repo |> git_output!(["rev-parse", "HEAD"]) |> String.trim()
    File.write!(Path.join(repo, protected_path), "check: edited\n")

    project = %Project{
      root: repo,
      name: "guard-fixture",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [protected_path],
      domains: %{"kernel" => ["lib/kogen/kernel"]}
    }

    intent = %Intent{
      slug: "guard-fixture",
      title: "Guard fixture",
      size: :small,
      brief: "Exercise the protected-file guard.",
      acceptance: [],
      domains: ["kernel"],
      notes: nil,
      path: "guard-fixture/intent.md",
      sha256: String.duplicate("a", 64)
    }

    manifest = %{protected_path => sha256(original)}

    assert {:error, %Failure{class: :candidate, reason: :protected_edit, detail: detail}} =
             Guard.check(repo, base_sha, intent, project, manifest, %{})

    assert detail =~ protected_path
  end

  test "rejects an info-excluded untracked file as out of scope", %{tmp_dir: tmp_dir} do
    origin = Git.create!(Path.join(tmp_dir, "origin"))
    base_sha = origin |> git_output!(["rev-parse", "HEAD"]) |> String.trim()
    workspace_root = Path.join([tmp_dir, ".kogen", "workspaces", "guard-fixture"])
    candidate_env = Git.env()

    assert {:ok, %{path: workdir}} =
             Workspace.create(origin, base_sha, workspace_root, "guard-run", candidate_env)

    File.write!(Path.join(workdir, "hidden.txt"), "still changed\n")
    File.write!(Path.join(workdir, ".git/info/exclude"), "hidden.txt\n")

    project = %Project{
      root: origin,
      name: "guard-fixture",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{"kernel" => ["lib/kogen/kernel"]}
    }

    intent = %Intent{
      slug: "guard-fixture",
      title: "Guard fixture",
      size: :small,
      brief: "Detect changes hidden by Candidate Git metadata.",
      acceptance: [],
      domains: ["kernel"],
      notes: nil,
      path: "guard-fixture/intent.md",
      sha256: String.duplicate("a", 64)
    }

    assert {:error, %Failure{class: :candidate, reason: :scope_edit, detail: detail}} =
             Guard.check(workdir, base_sha, intent, project, %{}, candidate_env)

    assert detail =~ "hidden.txt"
  end

  defp git!(repo, args), do: Proc.cmd!("git", ["-C", repo | args], env: git_env())

  defp git_output!(repo, args), do: Proc.cmd!("git", ["-C", repo | args], env: git_env())

  defp git_env do
    [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_AUTHOR_NAME", "Kogen Test"},
      {"GIT_AUTHOR_EMAIL", "test@kogen.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Test"},
      {"GIT_COMMITTER_EMAIL", "test@kogen.invalid"}
    ]
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
