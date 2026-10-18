defmodule Kogen.Integration.GitTest do
  use ExUnit.Case, async: true

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-git-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.name", "Fixture"])
    git!(root, ["config", "user.email", "fixture@example.invalid"])
    git!(root, ["config", "core.hooksPath", "/dev/null"])
    git!(root, ["config", "commit.gpgsign", "false"])
    git!(root, ["config", "status.renames", "copies"])

    File.write!(
      Path.join(root, "original name.txt"),
      String.duplicate("a substantial fixture line\n", 30)
    )

    git!(root, ["add", "."])
    git!(root, ["commit", "-qm", "baseline"])
    {:ok, root: root}
  end

  test "a staged rename reports both changed paths, including spaces", %{root: root} do
    git!(root, ["mv", "original name.txt", "new name.txt"])
    assert Enum.sort(Kogen.Git.changed_paths(root)) == ["new name.txt", "original name.txt"]
  end

  test "a detected copy does not also report its source as a rename deletion", %{root: root} do
    File.cp!(Path.join(root, "original name.txt"), Path.join(root, "copied name.txt"))
    File.write!(Path.join(root, "original name.txt"), "a later source edit\n", [:append])
    git!(root, ["add", "."])
    status = git!(root, ["status", "--porcelain=v1", "-z"])
    assert status =~ "C  copied name.txt\0original name.txt\0"
    assert Enum.sort(Kogen.Git.changed_paths(root)) == ["copied name.txt", "original name.txt"]
  end

  defp git!(root, args) do
    {output, status} =
      System.cmd("git", args,
        cd: root,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    output
  end
end
