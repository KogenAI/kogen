defmodule Kogen.GuardedPathsTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.GuardedPaths

  test "rejects an unguarded executable-bit change when core.filemode is false" do
    root =
      Path.join(System.tmp_dir!(), "kogen-guarded-paths-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "fixture@example.invalid"])
    git!(root, ["config", "user.name", "Fixture"])
    git!(root, ["config", "core.filemode", "false"])

    guarded = Path.join(root, "guarded.txt")
    unguarded = Path.join(root, "unguarded.sh")
    File.write!(guarded, "guarded\n")
    File.write!(unguarded, "#!/bin/sh\n")
    File.chmod!(unguarded, 0o644)
    git!(root, ["add", "guarded.txt", "unguarded.sh"])
    git!(root, ["commit", "-qm", "fixture"])

    assert {:ok, snapshot} = GuardedPaths.capture(root)
    File.chmod!(unguarded, 0o755)

    assert {:error, reason} = GuardedPaths.check(snapshot, ["guarded.txt"])
    assert reason =~ "unguarded.sh"
  end

  test "capture of a linked worktree snapshots Git's own config and exclude through git rev-parse --git-path, and a control-side config change fails check" do
    control =
      Path.join(System.tmp_dir!(), "kogen-guarded-paths-control-#{unique()}")

    candidate =
      Path.join(System.tmp_dir!(), "kogen-guarded-paths-candidate-#{unique()}")

    File.mkdir_p!(control)
    on_exit(fn -> File.rm_rf!(control) end)
    on_exit(fn -> File.rm_rf!(candidate) end)

    git!(control, ["init", "-q", "-b", "main"])
    git!(control, ["config", "user.email", "fixture@example.invalid"])
    git!(control, ["config", "user.name", "Fixture"])

    File.write!(Path.join(control, "tracked.txt"), "tracked\n")
    git!(control, ["add", "tracked.txt"])
    git!(control, ["commit", "-qm", "fixture"])

    git!(control, ["worktree", "add", "-q", "-b", "kogen/candidate", candidate, "main"])

    # A linked worktree's `.git` is a file, not a directory; capture must
    # still find Git's own config and exclude file through `--git-path`.
    assert File.regular?(Path.join(candidate, ".git"))
    assert {:ok, snapshot} = GuardedPaths.capture(candidate)
    assert snapshot.root == Path.expand(candidate)

    assert {".git/config", _control_git_config} =
             Enum.find(snapshot.files, fn {label, _path} -> label == ".git/config" end)

    assert :ok = GuardedPaths.check(snapshot, ["tracked.txt"])

    # Control's own `.git/config` is shared by every linked worktree; a
    # change to it after capture must still be detected from the Candidate.
    git!(control, ["config", "user.signingkey", "changed-after-capture"])

    assert {:error, reason} = GuardedPaths.check(snapshot, ["tracked.txt"])
    assert reason == "Git configuration or ignore policy changed during Developer turn"
  end

  test "ignored files written in the control checkout after capturing the Candidate never appear in the Candidate's check (shaping-during-build)" do
    control =
      Path.join(System.tmp_dir!(), "kogen-guarded-paths-control-#{unique()}")

    candidate =
      Path.join(System.tmp_dir!(), "kogen-guarded-paths-candidate-#{unique()}")

    File.mkdir_p!(Path.join(control, ".kogen/intents/drafts"))
    File.mkdir_p!(Path.join(control, ".kogen/intents/approved/existing-package"))
    on_exit(fn -> File.rm_rf!(control) end)
    on_exit(fn -> File.rm_rf!(candidate) end)

    git!(control, ["init", "-q", "-b", "main"])
    git!(control, ["config", "user.email", "fixture@example.invalid"])
    git!(control, ["config", "user.name", "Fixture"])
    File.write!(Path.join(control, ".gitignore"), ".kogen/\n")
    File.write!(Path.join(control, "tracked.txt"), "tracked\n")

    File.write!(
      Path.join(control, ".kogen/intents/approved/existing-package/INTENT.md"),
      "existing\n"
    )

    git!(control, ["add", "tracked.txt", ".gitignore"])
    git!(control, ["commit", "-qm", "fixture"])

    git!(control, ["worktree", "add", "-q", "-b", "kogen/candidate", candidate, "main"])

    assert {:ok, snapshot} = GuardedPaths.capture(candidate)

    # Mid-Build control-side writes: a new Draft, an edit to another Draft,
    # and a package moved into control's ignored Approved directory.
    File.write!(Path.join(control, ".kogen/intents/drafts/new-draft.md"), "draft\n")

    File.mkdir_p!(Path.join(control, ".kogen/intents/approved/moved-package"))

    File.write!(
      Path.join(control, ".kogen/intents/approved/moved-package/INTENT.md"),
      "moved\n"
    )

    File.write!(
      Path.join(control, ".kogen/intents/approved/existing-package/INTENT.md"),
      "existing edited\n"
    )

    # None of the control-side writes ever reach the Candidate's own check.
    assert :ok = GuardedPaths.check(snapshot, ["tracked.txt"])

    # The Candidate's own working tree (a distinct directory) is unaffected.
    refute File.exists?(Path.join(candidate, ".kogen/intents/drafts/new-draft.md"))
    refute File.exists?(Path.join(candidate, ".kogen/intents/approved/moved-package"))
  end

  defp unique, do: "#{System.pid()}-#{System.unique_integer([:positive])}"

  defp git!(root, args) do
    assert {_output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end
end
