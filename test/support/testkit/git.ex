defmodule Kogen.Testkit.Git do
  @moduledoc "Creates a small real Git repository for tests."

  alias Kogen.Testkit.Proc

  @git_env %{
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_CONFIG_COUNT" => "1",
    "GIT_CONFIG_KEY_0" => "commit.gpgsign",
    "GIT_CONFIG_VALUE_0" => "false",
    "GIT_AUTHOR_NAME" => "Kogen Test",
    "GIT_AUTHOR_EMAIL" => "test@kogen.invalid",
    "GIT_COMMITTER_NAME" => "Kogen Test",
    "GIT_COMMITTER_EMAIL" => "test@kogen.invalid",
    "GIT_AUTHOR_DATE" => "2026-10-02T00:00:00+00:00",
    "GIT_COMMITTER_DATE" => "2026-10-02T00:00:00+00:00"
  }

  @spec env() :: %{String.t() => String.t()}
  def env, do: @git_env

  @spec copy_tree!(Path.t(), Path.t()) :: :ok
  def copy_tree!(source, destination) do
    File.mkdir_p!(destination)

    _output =
      Proc.cmd!("/bin/cp", ["-c", "-R", Path.join(source, "."), destination],
        cd: destination,
        env: Map.to_list(@git_env)
      )

    :ok
  end

  @spec bare!(Path.t()) :: Path.t()
  def bare!(repo) do
    File.mkdir_p!(Path.dirname(repo))

    _output =
      Proc.cmd!(
        "git",
        ["-c", "commit.gpgsign=false", "init", "--bare", "--quiet", "--template=", repo],
        env: Map.to_list(@git_env)
      )

    _output = git!(repo, ["symbolic-ref", "HEAD", "refs/heads/main"])
    repo
  end

  @spec create!(Path.t()) :: Path.t()
  def create!(parent) do
    repo = Path.join(parent, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet", "--template="])
    File.write!(Path.join(repo, "README.md"), "fixture\n")
    git!(repo, ["add", "--all"])
    git!(repo, ["commit", "--quiet", "-m", "fixture"])
    repo
  end

  @spec git!(Path.t(), [String.t()]) :: String.t()
  def git!(repo, args) do
    Proc.cmd!(
      "git",
      ["-c", "commit.gpgsign=false", "-C", repo | args],
      env: Map.to_list(@git_env)
    )
  end
end
