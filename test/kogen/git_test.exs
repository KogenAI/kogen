defmodule Kogen.GitTest do
  @moduledoc """
  Direct tests of `Kogen.Git` against real temporary git repositories:
  `candidate_id/0`'s sensitivity to untracked files and `.gitignore`,
  `commit/3`'s trailers, and `assert_commit_diff_only/2`'s path check.

  `Kogen.Git` shells out to `git` against the process's current working
  directory, so every test uses `File.cd!/2` into its own disposable temp
  repo and the module is `async: false`.
  """
  use ExUnit.Case, async: false

  alias Kogen.Git

  @git_env [
    {"GIT_AUTHOR_NAME", "Kogen Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
  ]

  describe "candidate_id/0" do
    test "changes when an untracked file is added and reverts when it is removed" do
      dir = tmp_repo!()

      File.cd!(dir, fn ->
        assert {:ok, id_before} = Git.candidate_id()

        File.write!("untracked.txt", "hello\n")
        assert {:ok, id_with_file} = Git.candidate_id()
        assert id_with_file != id_before

        File.rm!("untracked.txt")
        assert {:ok, id_after_removal} = Git.candidate_id()
        assert id_after_removal == id_before
      end)
    end

    test "a file matching .gitignore does not change the candidate id" do
      dir = tmp_repo!()

      File.cd!(dir, fn ->
        File.write!(".gitignore", "ignored.txt\n")
        commit_all!("track gitignore")

        assert {:ok, id_before} = Git.candidate_id()

        File.write!("ignored.txt", "should be invisible\n")
        assert {:ok, id_after} = Git.candidate_id()

        assert id_after == id_before
      end)
    end
  end

  describe "commit/3" do
    test "produces a commit with the given subject and trailers" do
      dir = tmp_repo!()

      File.cd!(dir, fn ->
        File.write!("payload.txt", "candidate content\n")

        assert {:ok, head_sha} =
                 Git.commit("A sample subject line", "Some explanatory body text.", [
                   {"Kogen-Intent-Id", "01960000-0000-7000-8000-00000000feed"},
                   {"Kogen-Intent", "sample-slug"}
                 ])

        assert is_binary(head_sha)
        assert {out, 0} = System.cmd("git", ["rev-parse", "HEAD"])
        assert String.trim(out) == head_sha

        subject = git!(["log", "-1", "--format=%s"])
        assert subject == "A sample subject line"

        {trailer_out, 0} =
          System.cmd("sh", ["-c", "git log -1 --format=%B | git interpret-trailers --parse"])

        assert trailer_out =~ "Kogen-Intent-Id: 01960000-0000-7000-8000-00000000feed"
        assert trailer_out =~ "Kogen-Intent: sample-slug"
      end)
    end
  end

  describe "commit_staged/2" do
    test "publishes only the subject and supplied trailers without rewriting its parent" do
      dir = tmp_repo!()

      File.cd!(dir, fn ->
        parent = git!(["rev-parse", "HEAD"])
        File.write!("payload.txt", "candidate content\n")
        assert {_, 0} = System.cmd("git", ["add", "-A"])

        trailers = [
          {"Kogen-Intent-ID", "01960000-0000-7000-8000-00000000feed"},
          {"Kogen-Intent", "sample-slug"}
        ]

        assert {:ok, _head_sha} = Git.commit_staged("A sample subject line", trailers)

        message = raw_commit_message!()

        assert message ==
                 "A sample subject line\n\nKogen-Intent-ID: 01960000-0000-7000-8000-00000000feed\nKogen-Intent: sample-slug\n"

        assert parsed_trailers!(message) ==
                 [
                   "Kogen-Intent-ID: 01960000-0000-7000-8000-00000000feed",
                   "Kogen-Intent: sample-slug"
                 ]

        assert git!(["rev-parse", "HEAD^"]) == parent
      end)
    end
  end

  describe "assert_commit_diff_only/2" do
    test "returns :ok when the only diff between the candidate tree and HEAD is under the allowed prefix" do
      dir = tmp_repo!()

      File.cd!(dir, fn ->
        File.mkdir_p!("allowed")
        File.write!("allowed/one.txt", "v1\n")
        commit_all!("baseline with allowed dir")

        assert {:ok, candidate_tree} = Git.candidate_id()

        File.write!("allowed/one.txt", "v2\n")
        commit_all!("change only under allowed/")

        assert Git.assert_commit_diff_only(candidate_tree, "allowed/") == :ok
      end)
    end

    test "returns an error naming paths outside the allowed prefix when one changed too" do
      dir = tmp_repo!()

      File.cd!(dir, fn ->
        File.mkdir_p!("allowed")
        File.write!("allowed/one.txt", "v1\n")
        File.write!("outside.txt", "v1\n")
        commit_all!("baseline with allowed dir and outside file")

        assert {:ok, candidate_tree} = Git.candidate_id()

        File.write!("allowed/one.txt", "v2\n")
        File.write!("outside.txt", "v2\n")
        commit_all!("change both allowed/ and an outside file")

        assert {:error, {:paths_outside_allowed, bad_paths}} =
                 Git.assert_commit_diff_only(candidate_tree, "allowed/")

        assert bad_paths == ["outside.txt"]
      end)
    end
  end

  # -- helpers -------------------------------------------------------------

  defp tmp_repo! do
    dir = Path.join(System.tmp_dir!(), "kogen-git-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dir)
    File.write!(Path.join(dir, "README.txt"), "baseline\n")

    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: dir, env: @git_env)

    dir
  end

  defp commit_all!(message) do
    {_out, 0} = System.cmd("git", ["add", "-A"])
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", message], env: @git_env)
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args)
    String.trim(out)
  end

  defp raw_commit_message! do
    {commit, 0} = System.cmd("git", ["cat-file", "commit", "HEAD"])
    [_headers, message] = String.split(commit, "\n\n", parts: 2)
    message
  end

  defp parsed_trailers!(message) do
    path = Path.join(System.tmp_dir!(), "kogen-trailers-#{System.unique_integer([:positive])}")

    try do
      File.write!(path, message)
      {out, 0} = System.cmd("git", ["interpret-trailers", "--parse", path])
      String.split(out, "\n", trim: true)
    after
      File.rm(path)
    end
  end
end
