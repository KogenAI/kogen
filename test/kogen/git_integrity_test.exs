defmodule Kogen.GitIntegrityTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Git

  @git_env [
    {"GIT_AUTHOR_NAME", "Kogen Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
  ]

  test "readiness status does not refresh or rewrite the real index" do
    in_repo!(fn ->
      File.write!("stat-refresh.txt", "unchanged bytes")
      commit_all!("track stat fixture")
      File.rm!("stat-refresh.txt")
      File.write!("stat-refresh.txt", "unchanged bytes")
      before = File.read!(".git/index")
      assert Git.clean_worktree?()
      assert File.read!(".git/index") == before
    end)
  end

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

  test "exact publication assertions require the staged and committed Candidate tree" do
    in_repo!(fn ->
      File.write!("candidate.txt", "reviewed\n")
      assert {:ok, candidate} = Git.candidate_id()

      assert {:error, staged_error} = Git.assert_staged_tree(candidate)
      assert staged_error =~ "staged Git tree differs"

      assert {_out, 0} = System.cmd("git", ["add", "-A"])
      assert :ok = Git.assert_staged_tree(candidate)
      assert {:error, head_error} = Git.assert_head_tree(candidate)
      assert head_error =~ "HEAD Git tree differs"

      commit_all!("publish candidate")
      assert :ok = Git.assert_head_tree(candidate)
    end)
  end

  test "publication budget accepts equality and rejects one byte over each fixed limit" do
    in_repo!(fn ->
      File.write!("exact.bin", :binary.copy(<<0>>, 5_242_880))
      File.write!("remainder.bin", :binary.copy(<<1>>, 5_242_880))
      assert {_out, 0} = System.cmd("git", ["add", "-A"])
      assert :ok = Git.validate_staged_publication()

      File.write!("remainder.bin", :binary.copy(<<1>>, 5_242_881))
      assert {_out, 0} = System.cmd("git", ["add", "-A"])
      assert {:error, aggregate} = Git.validate_staged_publication()
      assert aggregate =~ "changed blob total 10485761 exceeds 10485760"
      assert aggregate =~ "remainder.bin"

      File.rm!("exact.bin")
      File.write!("remainder.bin", :binary.copy(<<1>>, 5_242_881))
      assert {_out, 0} = System.cmd("git", ["add", "-A"])
      assert {:error, per_file} = Git.validate_staged_publication()
      assert per_file =~ "files over 5242880 bytes"
      assert per_file =~ "remainder.bin"
    end)
  end

  test "publication budget rejects force-staged runtime paths with unambiguous names" do
    in_repo!(fn ->
      File.write!(".gitignore", ".kogen/runtime/\n")
      commit_all!("ignore runtime")
      File.mkdir_p!(".kogen/runtime")
      path = ".kogen/runtime/evidence with space\nand newline"
      File.write!(path, "small")
      assert {_out, 0} = System.cmd("git", ["add", "-f", "--", path])
      assert {:error, reason} = Git.validate_staged_publication()
      assert reason =~ "staged runtime paths"
      assert reason =~ inspect(path)
    end)
  end

  for {flag, label} <- [
        {"--assume-unchanged", "assume-unchanged"},
        {"--skip-worktree", "skip-worktree"}
      ] do
    test "Candidate capture and publication refuse a #{label} index flag without changing the index" do
      in_repo!(fn ->
        File.write!("README.md", "changed behind the flag\n")
        assert {_out, 0} = System.cmd("git", ["update-index", unquote(flag), "README.md"])
        assert {index_before, 0} = System.cmd("git", ["write-tree"])
        assert {head_before, 0} = System.cmd("git", ["rev-parse", "HEAD"])
        assert {flag_before, 0} = System.cmd("git", ["ls-files", "-v", "README.md"])

        assert {:error, reason} = Git.candidate_id()
        assert reason =~ "Candidate identity refused"
        assert reason =~ unquote(label)

        assert {:error, ^reason} = Git.stage_and_verify_candidate(index_before, "complete/")
        assert {:error, ^reason} = Git.assert_staged_tree(index_before)
        assert {:error, ^reason} = Git.assert_head_tree(index_before)
        assert {:error, ^reason} = Git.commit("blocked publication", "", [])
        assert {:error, ^reason} = Git.commit_staged("blocked publication", [])
        assert {^index_before, 0} = System.cmd("git", ["write-tree"])
        assert {^head_before, 0} = System.cmd("git", ["rev-parse", "HEAD"])
        assert {^flag_before, 0} = System.cmd("git", ["ls-files", "-v", "README.md"])
      end)
    end
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
