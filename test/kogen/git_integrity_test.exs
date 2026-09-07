defmodule Kogen.GitIntegrityTest do
  use ExUnit.Case, async: false

  alias Kogen.Git

  @git_env [
    {"GIT_AUTHOR_NAME", "Kogen Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
  ]

  test "Candidate retains a deliberately staged ignored path" do
    in_repo!(fn ->
      File.write!(".gitignore", "generated/\n")
      commit_all!("ignore generated")

      assert {:ok, before} = Git.candidate_id()
      File.mkdir_p!("generated")
      File.write!("generated/forced.txt", "kept in the real index\n")
      assert {_out, 0} = System.cmd("git", ["add", "-f", "generated/forced.txt"])

      assert {:ok, after_staging} = Git.candidate_id()
      assert after_staging != before
    end)
  end

  test "Candidate includes updates to an already tracked ignored file without changing the real index" do
    in_repo!(fn ->
      File.mkdir_p!("generated")
      File.write!("generated/tracked.txt", "old\n")
      commit_all!("track generated file")
      File.write!(".gitignore", "generated/\n")
      commit_all!("ignore generated")
      {index_before, 0} = System.cmd("git", ["write-tree"])
      File.write!("generated/tracked.txt", "review this update\n")
      File.write!("generated/untracked.txt", "keep private\n")

      assert {:ok, candidate} = Git.candidate_id()

      assert {"review this update\n", 0} =
               System.cmd("git", ["show", "#{candidate}:generated/tracked.txt"])

      assert {"", 0} = System.cmd("git", ["ls-tree", candidate, "generated/untracked.txt"])
      assert {^index_before, 0} = System.cmd("git", ["write-tree"])
    end)
  end

  test "stage verification rejects an outside path including a quoted Git filename" do
    in_repo!(fn ->
      File.write!("candidate.txt", "reviewed\n")
      assert {:ok, candidate} = Git.candidate_id()

      File.mkdir_p!("complete/intent")
      File.write!("complete/intent/evidence.md", "Kogen evidence\n")
      File.write!("outside with space.txt", "not reviewed\n")

      assert {:error, {:paths_outside_allowed, ["outside with space.txt"]}} =
               Git.stage_and_verify_candidate(candidate, "complete/")
    end)
  end

  defp in_repo!(fun) do
    dir =
      Path.join(System.tmp_dir!(), "kogen-git-integrity-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    assert {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dir)
    File.write!(Path.join(dir, "README.md"), "fixture\n")
    assert {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)

    assert {_out, 0} =
             System.cmd("git", ["commit", "-q", "-m", "baseline"], cd: dir, env: @git_env)

    File.cd!(dir, fun)
  end

  defp commit_all!(message) do
    assert {_out, 0} = System.cmd("git", ["add", "-A"])
    assert {_out, 0} = System.cmd("git", ["commit", "-q", "-m", message], env: @git_env)
  end
end
