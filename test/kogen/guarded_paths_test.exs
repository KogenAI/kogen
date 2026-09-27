defmodule Kogen.GuardedPathsTest do
  # `Kogen.IsolatedCase`, not plain `ExUnit.Case`: the fake-harness Build test
  # below calls `Kogen.WorkspaceFixture.build!/2`, which mutates process-wide
  # environment (`System.put_env/2`, `KOGEN_HARNESS` among others). Sharing
  # the outer async VM with another concurrent fake-harness Build races that
  # environment, as every other `Fixture.build!` test in this suite already
  # avoids by using `Kogen.IsolatedCase`.
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.GuardedPaths
  alias Kogen.WorkspaceFixture, as: Fixture

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

    # An ordinary unguarded change is returned for a guard rework.
    assert {{:rework, ["unguarded.sh"]}, _snapshot, []} =
             GuardedPaths.check(snapshot, ["guarded.txt"])
  end

  test "capture of a linked worktree snapshots Git's own config and exclude through git rev-parse --git-path, and a control-side config change is one environment event" do
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

    assert {:ok, ^snapshot, []} = GuardedPaths.check(snapshot, ["tracked.txt"])

    # Control's own `.git/config` is shared by every linked worktree; a
    # change to it after capture is still detected from the Candidate, now as
    # an environment event of control (lessons 19, 22), not a stop.
    old_config = File.read!(Path.join(control, ".git/config"))
    git!(control, ["config", "user.signingkey", "changed-after-capture"])
    new_config = File.read!(Path.join(control, ".git/config"))

    assert {:ok, refreshed, [event]} = GuardedPaths.check(snapshot, ["tracked.txt"])

    assert event == %{
             file: ".git/config",
             before: sha256(old_config),
             after: sha256(new_config)
           }

    # The refreshed snapshot reports the event once, never again.
    assert {:ok, ^refreshed, []} = GuardedPaths.check(refreshed, ["tracked.txt"])
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
    assert {:ok, _snapshot, []} = GuardedPaths.check(snapshot, ["tracked.txt"])

    # The Candidate's own working tree (a distinct directory) is unaffected.
    refute File.exists?(Path.join(candidate, ".kogen/intents/drafts/new-draft.md"))
    refute File.exists?(Path.join(candidate, ".kogen/intents/approved/moved-package"))
  end

  # Scenario `declared-gitignore-edit`: `.gitignore` is an ordinary guarded
  # path, checked through `changed_paths/3` like any tracked file, not part
  # of the frozen `same_config` set. This reproduces evidence/probe-gitignore's
  # table.
  describe "`.gitignore` as an ordinary guarded path" do
    setup do
      root = Path.join(System.tmp_dir!(), "kogen-guarded-gitignore-#{unique()}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, ".gitignore"), "*.log\n")
      File.write!(Path.join(root, "a.txt"), "a\n")

      git!(root, ["init", "-q"])
      git!(root, ["config", "user.email", "fixture@example.invalid"])
      git!(root, ["config", "user.name", "Fixture"])
      git!(root, ["add", "-A"])
      git!(root, ["commit", "-qm", "base"])

      assert {:ok, snapshot} = GuardedPaths.capture(root)
      %{root: root, snapshot: snapshot}
    end

    test "a hiding edit with only `.gitignore` declared still names the hidden file", %{
      root: root,
      snapshot: snapshot
    } do
      File.write!(Path.join(root, ".gitignore"), "*.log\nhidden.txt\n")
      File.write!(Path.join(root, "hidden.txt"), "sneaky\n")

      # The hidden file alone is an ordinary stray path, now reworked.
      assert {{:rework, ["hidden.txt"]}, _snapshot, []} =
               GuardedPaths.check(snapshot, [".gitignore"])
    end

    test "a hiding edit with `.gitignore` undeclared names both the file and `.gitignore`", %{
      root: root,
      snapshot: snapshot
    } do
      File.write!(Path.join(root, ".gitignore"), "*.log\nhidden.txt\n")
      File.write!(Path.join(root, "hidden.txt"), "sneaky\n")

      # An unguarded root `.gitignore` change is terminal Git policy.
      assert {{:stop, "git-policy", reason}, _snapshot, []} = GuardedPaths.check(snapshot, [])
      assert reason =~ ".gitignore"
      assert reason =~ "hidden.txt"
    end

    test "a hiding edit passes once both `.gitignore` and the hidden file are declared", %{
      root: root,
      snapshot: snapshot
    } do
      File.write!(Path.join(root, ".gitignore"), "*.log\nhidden.txt\n")
      File.write!(Path.join(root, "hidden.txt"), "sneaky\n")

      assert {:ok, _snapshot, []} = GuardedPaths.check(snapshot, [".gitignore", "hidden.txt"])
    end

    test "a declared `.gitignore`-only edit that hides nothing passes", %{
      root: root,
      snapshot: snapshot
    } do
      File.write!(Path.join(root, ".gitignore"), "*.log\n*.pid\n")

      assert {:ok, _snapshot, []} = GuardedPaths.check(snapshot, [".gitignore"])
    end

    test "an undeclared `.gitignore`-only edit stops as git-policy with the stray-path message",
         %{
           root: root,
           snapshot: snapshot
         } do
      File.write!(Path.join(root, ".gitignore"), "*.log\n*.pid\n")

      # The root `.gitignore` is the Candidate's Git policy: terminal, with
      # today's stray-path message.
      assert {{:stop, "git-policy", reason}, _snapshot, []} = GuardedPaths.check(snapshot, [])
      assert reason == "Candidate changed paths outside Approved guards: .gitignore"
    end

    test "`.git/config` and `.git/info/exclude` changes are environment events even when `.gitignore` is declared, while a `.gitmodules` edit stays git-policy",
         %{root: root, snapshot: snapshot} do
      assert {:ok, ^snapshot, []} = GuardedPaths.check(snapshot, [".gitignore"])

      # Shared Git files are control's: events, not stops.
      git!(root, ["config", "user.signingkey", "changed-after-capture"])
      File.write!(Path.join(root, ".git/info/exclude"), "/no-such-path\n", [:append])

      assert {:ok, refreshed, events} = GuardedPaths.check(snapshot, [".gitignore"])
      assert Enum.map(events, & &1.file) == [".git/config", ".git/info/exclude"]

      # The Candidate's own `.gitmodules` keeps the configuration stop.
      File.write!(Path.join(root, ".gitmodules"), "[submodule \"x\"]\n")

      assert {{:stop, "git-policy", reason}, _snapshot, []} =
               GuardedPaths.check(refreshed, [".gitignore"])

      assert reason == "Git configuration or ignore policy changed during Developer turn"
    end

    test "after an exclude event a path whose ignored state changed stops as git-policy, guarded or not",
         %{root: root, snapshot: snapshot} do
      File.write!(Path.join(root, ".git/info/exclude"), "/hidden.txt\n", [:append])
      File.write!(Path.join(root, "hidden.txt"), "sneaky\n")

      for guards <- [[], ["hidden.txt"]] do
        assert {{:stop, "git-policy", reason}, refreshed, _events} =
                 GuardedPaths.check(snapshot, guards)

        assert reason ==
                 "Control's .git/info/exclude changed the ignored state of Candidate paths: hidden.txt"

        # Every later handoff still compares with the Build-start exclude.
        assert {{:stop, "git-policy", ^reason}, _snapshot, []} =
                 GuardedPaths.check(refreshed, guards)
      end
    end
  end

  test "a fake-harness Build whose Intent declares `.gitignore` and edits it reaches Review" do
    control = Fixture.create!(guards: ["dummy.txt", ".gitignore"])
    on_exit(fn -> File.rm_rf(control) end)

    tools = Fixture.tmp_dir!("gitignore-edit-role")
    role = Fixture.waiting_role!(tools, Fixture.support("fake_codex_simple_accept"))
    edit = "printf '*.tmp\\n' >> .gitignore"

    task =
      Task.async(fn ->
        Fixture.build!(control, harness: role, env: [{"FIXTURE_DEV_EDIT", edit}])
      end)

    home = Fixture.await_waiting!(control)
    File.write!(Path.join(home, "go"), "")
    assert :ok = Task.await(task, 180_000)

    assert File.read!(Path.join(control, ".gitignore")) =~ "*.tmp"
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp unique, do: "#{System.pid()}-#{System.unique_integer([:positive])}"

  defp git!(root, args) do
    assert {_output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end
end
