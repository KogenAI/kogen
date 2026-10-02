defmodule Kogen.Testkit.Git do
  @moduledoc "Creates a small real Git repository for tests."

  @git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_AUTHOR_NAME", "Kogen Test"},
    {"GIT_AUTHOR_EMAIL", "test@kogen.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Test"},
    {"GIT_COMMITTER_EMAIL", "test@kogen.invalid"},
    {"GIT_AUTHOR_DATE", "2026-10-02T00:00:00+00:00"},
    {"GIT_COMMITTER_DATE", "2026-10-02T00:00:00+00:00"}
  ]

  @spec create!(Path.t()) :: Path.t()
  def create!(parent) do
    repo = Path.join(parent, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet", "--template="])
    File.write!(Path.join(repo, "README.md"), "fixture\n")
    git!(repo, ["add", "--all"])
    git!(repo, ["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"])
    repo
  end

  defp git!(repo, args) do
    _ = Kogen.Testkit.Proc.cmd!("git", ["-C", repo | args], env: @git_env)
    :ok
  end
end
