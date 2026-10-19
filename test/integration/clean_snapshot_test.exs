defmodule Kogen.Integration.CleanSnapshotTest do
  use ExUnit.Case, async: true
  alias Kogen.{Git, Snapshot}

  @moduletag :integration

  test "declared Git commands see the exact clean inputs without workspace artifacts" do
    root = Kogen.tmp_path("kogen-clean-input-test")
    scratch = Kogen.tmp_path("kogen-clean-input-copy")
    File.mkdir_p!(root)
    on_exit(fn -> Enum.each([root, scratch], &File.rm_rf!/1) end)
    Git.ok!(root, ["init", "-q", "--template="])
    Git.ok!(root, ["config", "user.name", "Fixture"])
    Git.ok!(root, ["config", "user.email", "fixture@example.invalid"])
    Git.ok!(root, ["config", "commit.gpgsign", "false"])
    Git.ok!(root, ["config", "core.hooksPath", ".git/hooks"])
    File.write!(Path.join(root, ".gitignore"), "build/\n")
    File.write!(Path.join(root, "app.sh"), "printf 'before\\n'\n")
    File.mkdir_p!(Path.join(root, "build"))
    File.write!(Path.join(root, "build/tracked.txt"), "tracked ignored input\n")
    Git.ok!(root, ["add", "-f", ".gitignore", "app.sh", "build/tracked.txt"])
    Git.ok!(root, ["commit", "-qm", "Fixture baseline"])
    start = Git.head(root)
    File.write!(Path.join(root, "app.sh"), "printf 'candidate\\n'\n")
    File.chmod!(Path.join(root, "app.sh"), 0o755)
    File.write!(Path.join(root, "new.txt"), "new candidate\n")
    File.ln_s!("new.txt", Path.join(root, "link"))
    File.write!(Path.join(root, "build/undeclared.sh"), "workspace only\n")
    tree = Snapshot.tree(root, start, [])
    input = Snapshot.materialize(root, tree, scratch)

    assert String.trim(Git.ok!(scratch, ["rev-parse", "HEAD^{tree}"])) == tree
    assert Git.ok!(scratch, ["show", "HEAD:app.sh"]) == File.read!(Path.join(root, "app.sh"))
    assert Git.ok!(scratch, ["show", "HEAD:link"]) == "new.txt"
    assert Git.ok!(scratch, ["ls-files", "--error-unmatch", "new.txt"]) == "new.txt\n"
    assert Git.ok!(scratch, ["status", "--porcelain"]) == ""
    refute File.exists?(Path.join(scratch, "build/undeclared.sh"))
    assert Snapshot.mutations(scratch, input) == []
    File.chmod!(Path.join(scratch, "app.sh"), 0o644)
    assert Snapshot.mutations(scratch, input) == ["app.sh"]
    File.chmod!(Path.join(scratch, "app.sh"), 0o755)
    File.rm!(Path.join(scratch, "link"))
    File.ln_s!("app.sh", Path.join(scratch, "link"))
    assert Snapshot.mutations(scratch, input) == ["link"]
    File.rm!(Path.join(scratch, "link"))
    File.ln_s!("new.txt", Path.join(scratch, "link"))
    File.rm!(Path.join(scratch, "new.txt"))
    assert Snapshot.mutations(scratch, input) == ["new.txt"]
    File.write!(Path.join(scratch, "new.txt"), "new candidate\n")
    File.write!(Path.join(scratch, "check-input.txt"), "added by a declared command\n")
    Git.ok!(scratch, ["add", "check-input.txt"])
    assert Snapshot.mutations(scratch, input) == ["check-input.txt"]
    Git.ok!(scratch, ["rm", "-q", "-f", "check-input.txt"])
    File.write!(Path.join(scratch, "build/generated.sh"), "declared output\n")
    Git.ok!(scratch, ["add", "-f", "build/generated.sh"])
    assert Snapshot.mutations(scratch, input) == []
    File.write!(Path.join(scratch, "build/tracked.txt"), "mutated\n")
    assert Snapshot.mutations(scratch, input) == ["build/tracked.txt"]
  end

  test "gitlink inputs retain their exact commit and clean tracked contents" do
    root = Kogen.tmp_path("kogen-clean-gitlink-test")
    scratch = Kogen.tmp_path("kogen-clean-gitlink-copy")
    File.mkdir_p!(Path.join(root, "module"))
    on_exit(fn -> Enum.each([root, scratch], &File.rm_rf!/1) end)

    init = fn dir ->
      Git.ok!(dir, ["init", "-q", "--template="])
      Git.ok!(dir, ["config", "user.name", "Fixture"])
      Git.ok!(dir, ["config", "user.email", "fixture@example.invalid"])
      Git.ok!(dir, ["config", "commit.gpgsign", "false"])
      Git.ok!(dir, ["config", "core.hooksPath", ".git/hooks"])
    end

    dependency = fn dir ->
      init.(dir)
      File.write!(Path.join(dir, "app.txt"), "candidate dependency\n")
      File.write!(Path.join(dir, ".gitignore"), "cache/\n")
      Git.ok!(dir, ["add", "."])

      Git.ok!(dir, ["commit", "-qm", "Candidate dependency"],
        env: [
          {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"},
          {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"}
        ]
      )
    end

    init.(root)
    dependency.(Path.join(root, "module"))
    expected = Git.head(Path.join(root, "module"))
    File.write!(Path.join(root, ".gitignore"), "module/cache/\n")
    Git.ok!(root, ["add", "."])
    Git.ok!(root, ["commit", "-qm", "Fixture"])
    tree = Snapshot.tree(root, Git.head(root), [])
    input = Snapshot.materialize(root, tree, scratch)
    assert Snapshot.mutations(scratch, input) == []
    File.write!(Path.join(scratch, "module/untracked.txt"), "added input\n")
    assert Snapshot.mutations(scratch, input) == ["module/untracked.txt"]
    File.rm!(Path.join(scratch, "module/untracked.txt"))
    File.mkdir_p!(Path.join(scratch, "module/cache"))
    File.write!(Path.join(scratch, "module/cache/generated.txt"), "declared output\n")
    assert Snapshot.mutations(scratch, input) == []
    dependency.(Path.join(scratch, "module"))
    assert Git.head(Path.join(scratch, "module")) == expected
    assert Snapshot.mutations(scratch, input) == []
    Git.ok!(Path.join(scratch, "module"), ["add", "-f", "cache/generated.txt"])
    assert Snapshot.mutations(scratch, input) == []
    File.write!(Path.join(scratch, "module/untracked.txt"), "added input\n")
    Git.ok!(Path.join(scratch, "module"), ["add", "untracked.txt"])
    assert Snapshot.mutations(scratch, input) == ["module"]
    Git.ok!(Path.join(scratch, "module"), ["rm", "-q", "-f", "untracked.txt"])
    File.write!(Path.join(scratch, "module/app.txt"), "different dependency\n")
    assert Snapshot.mutations(scratch, input) == ["module"]
    Git.ok!(Path.join(scratch, "module"), ["add", "app.txt"])
    Git.ok!(Path.join(scratch, "module"), ["commit", "-qm", "Different dependency"])
    refute Git.head(Path.join(scratch, "module")) == expected
    assert Snapshot.mutations(scratch, input) == ["module"]
  end
end
