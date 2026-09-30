defmodule Kogen.TrackedIgnoredFilesTest do
  @moduledoc """
  Scenario `no-tracked-caches`: no tracked file matches an existing ignore
  rule, and no tracked file matches a hard-coded repository trash pattern
  (`*.pid`, `*.md.last`, `*.md.log`, `.kogen/intents/**/*run.log`,
  `.DS_Store`). `.gitignore` itself is never edited by this check. The whole
  test skips, naming why, on a tree with no Git: the gitless `cold-offline`
  copy has neither Git nor `.kogen/intents`
  (`test/kogen/cold_offline_test.exs:188-192`).
  """
  # `Kogen.IsolatedCase`, not plain `ExUnit.Case`: the fake-harness Build test
  # below calls `Kogen.WorkspaceFixture.build!/2`, which mutates process-wide
  # environment (`System.put_env/2`, `KOGEN_HARNESS` among others). Sharing
  # the outer async VM with another concurrent fake-harness Build races that
  # environment, as every other `Fixture.build!` test in this suite already
  # avoids by using `Kogen.IsolatedCase`.
  use Kogen.IsolatedCase, async: true

  alias Kogen.WorkspaceFixture, as: Fixture

  @cited_logs [
    ".kogen/intents/complete/isolated-candidate-workspace/evidence/b1-make-check-in-worktree-2026-09-24.log",
    ".kogen/intents/complete/isolated-candidate-workspace/evidence/b1-make-check-space-path-2026-09-24.log",
    ".kogen/intents/complete/isolated-candidate-workspace/evidence/reshape-2026-09-26-98ebcfb2/focused-tests.log"
  ]

  # A gitless tree (the `cold-offline` copy, `cold_offline_test.exs:188-192`)
  # has neither `.git` nor `.kogen/intents`; the whole describe block skips
  # there instead of failing. Checked once per compile of this test file,
  # the same tree it will run against.
  @repository_root Path.expand("../..", __DIR__)
  # `.git` is a regular file (not a directory) inside a linked worktree.
  @has_git_and_intents File.exists?(Path.join(@repository_root, ".git")) and
                         File.dir?(Path.join(@repository_root, ".kogen/intents"))
  @skip_unless_git_and_intents if @has_git_and_intents,
                                 do: false,
                                 else:
                                   "no Git and no .kogen/intents in this tree (the gitless " <>
                                     "cold-offline copy, test/kogen/cold_offline_test.exs:188-192)"

  describe "this repository's own tracked files" do
    @describetag skip: @skip_unless_git_and_intents

    setup do
      {:ok, root: @repository_root}
    end

    test "no tracked file matches an existing ignore rule or a trash pattern", %{root: root} do
      assert %{ignored: [], trash: []} = offenders(root)
    end

    test "the three logs a package document cites still exist, byte-identical to their tracked content",
         %{root: root} do
      for relative <- @cited_logs do
        path = Path.join(root, relative)
        assert File.regular?(path), "cited log missing: #{relative}"

        assert {tracked, 0} = System.cmd("git", ["show", "HEAD:#{relative}"], cd: root)
        assert File.read!(path) == tracked, "cited log changed on disk: #{relative}"
      end
    end
  end

  describe "control fixture repository" do
    test "fixture repos ignore the machine's global excludes" do
      global = Path.join(System.tmp_dir!(), "kogen-global-gitconfig-#{unique()}")
      excludes = global <> "-excludes"
      File.write!(excludes, ".DS_Store\n")
      File.write!(global, "[core]\n\texcludesFile = #{excludes}\n")

      on_exit(fn ->
        File.rm(global)
        File.rm(excludes)
      end)

      System.put_env("GIT_CONFIG_GLOBAL", global)

      root = git_fixture!()
      write!(root, ".DS_Store")
      git!(root, ["add", "-A"])
      git!(root, ["commit", "-qm", "base"])

      assert ".DS_Store" in ls_files(root, ["-z"])
    end

    test "a tracked file already matched by an ignore rule fails, naming that file" do
      root = git_fixture!()
      File.write!(Path.join(root, ".gitignore"), "*.log\n")
      File.write!(Path.join(root, "kept.txt"), "kept\n")
      git!(root, ["add", "-A"])
      git!(root, ["commit", "-qm", "base"])

      # Force-add a file the fixture's own .gitignore already ignores, the
      # same defect this test catches in the real repository.
      File.write!(Path.join(root, "already-ignored.log"), "trash\n")
      git!(root, ["add", "-f", "already-ignored.log"])
      git!(root, ["commit", "-qm", "trash committed anyway"])

      assert %{ignored: ["already-ignored.log"], trash: []} = offenders(root)
    end

    test "a tracked file matching a hard-coded trash pattern fails, naming that file" do
      root = git_fixture!()
      File.write!(Path.join(root, "kept.txt"), "kept\n")

      for path <- ~w(sub/leftover.pid notes/a.md.last notes/a.md.log .DS_Store),
          do: write!(root, path)

      write!(root, ".kogen/intents/complete/x/evidence/jev-run.log")
      write!(root, "logs/run.log")
      git!(root, ["add", "-A"])
      git!(root, ["commit", "-qm", "base with trash"])

      # Patterns, not paths: a `run.log` outside `.kogen/intents` is not trash.
      assert %{ignored: [], trash: trash} = offenders(root)

      assert Enum.sort(trash) ==
               Enum.sort(
                 ~w(sub/leftover.pid notes/a.md.last notes/a.md.log .DS_Store) ++
                   [".kogen/intents/complete/x/evidence/jev-run.log"]
               )
    end

    test "a tracked file that matches neither an ignore rule nor a trash pattern passes" do
      root = git_fixture!()
      File.write!(Path.join(root, ".gitignore"), "*.log\n")
      File.write!(Path.join(root, "kept.txt"), "kept\n")
      git!(root, ["add", "-A"])
      git!(root, ["commit", "-qm", "base"])

      assert %{ignored: [], trash: []} = offenders(root)
    end

    test "a file the Candidate deleted is judged by the Candidate tree, not the stale index" do
      root = git_fixture!()
      File.write!(Path.join(root, ".gitignore"), "__pycache__/\n")
      write!(root, "kept.txt")
      write!(root, "sub/leftover.pid")
      git!(root, ["add", "-A"])
      write!(root, "__pycache__/x.pyc")
      git!(root, ["add", "-f", "__pycache__/x.pyc"])
      git!(root, ["commit", "-qm", "trash committed"])

      assert %{ignored: ["__pycache__/x.pyc"], trash: ["sub/leftover.pid"]} = offenders(root)

      # The Candidate id is a write-tree of the working tree, so a deletion not
      # yet staged is already absent from what the Build verifies and commits.
      File.rm!(Path.join(root, "__pycache__/x.pyc"))
      File.rm!(Path.join(root, "sub/leftover.pid"))
      assert %{ignored: [], trash: []} = offenders(root)
    end
  end

  describe "a fake-harness Build's Candidate deletion of a tracked __pycache__ file" do
    test "carries into the published commit even though GuardedPaths treats __pycache__ as volatile" do
      control = Fixture.create!()
      on_exit(fn -> File.rm_rf(control) end)

      pycache_relative = "test/support/shaping_evaluation/__pycache__/probe.cpython-314.pyc"
      pycache_path = Path.join(control, pycache_relative)
      File.mkdir_p!(Path.dirname(pycache_path))
      File.write!(pycache_path, "bytecode\n")
      Fixture.git!(control, ["add", "-A"])
      Fixture.git!(control, ["commit", "-qm", "tracked pycache baseline"])

      assert Fixture.git!(control, ["ls-files", pycache_relative]) != ""

      tools = Fixture.tmp_dir!("pycache-delete-role")
      role = Fixture.waiting_role!(tools, Fixture.support("fake_codex_simple_accept"))
      edit = "rm #{pycache_relative}"

      task =
        Task.async(fn ->
          Fixture.build!(control, harness: role, env: [{"FIXTURE_DEV_EDIT", edit}])
        end)

      home = Fixture.await_waiting!(control)
      File.write!(Path.join(home, "go"), "")
      assert :ok = Task.await(task, 180_000)

      refute File.exists?(pycache_path)
      assert Fixture.git!(control, ["ls-files", pycache_relative]) == ""
    end
  end

  @trash_dsl [
    {:suffix, ".pid"},
    {:suffix, ".md.last"},
    {:suffix, ".md.log"},
    {:intents_run_log, nil},
    {:basename, ".DS_Store"}
  ]

  defp trash_pattern?(path) do
    Enum.any?(@trash_dsl, fn
      {:suffix, suffix} -> String.ends_with?(path, suffix)
      {:basename, name} -> Path.basename(path) == name
      {:intents_run_log, nil} -> intents_run_log?(path)
    end)
  end

  defp intents_run_log?(path) do
    String.starts_with?(path, ".kogen/intents/") and String.ends_with?(path, "run.log")
  end

  # The check itself, shared by the repository and the control fixtures:
  # tracked files still present in the working tree (the Candidate tree the
  # Build verifies and publishes) that an existing ignore rule already
  # matches, or that match a hard-coded trash pattern.
  defp offenders(root) do
    ignored =
      root
      |> ls_files(["-ci", "--exclude-standard", "-z"])
      |> Enum.filter(&File.exists?(Path.join(root, &1)))

    trash =
      root
      |> ls_files(["-z"])
      |> Enum.filter(&(trash_pattern?(&1) and File.exists?(Path.join(root, &1))))

    %{ignored: ignored, trash: trash}
  end

  defp ls_files(root, args) do
    assert {output, 0} = System.cmd("git", ["ls-files" | args], cd: root)
    String.split(output, <<0>>, trim: true)
  end

  defp write!(root, relative) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "x\n")
  end

  defp git_fixture! do
    root =
      Path.join(System.tmp_dir!(), "kogen-tracked-ignored-#{unique()}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "fixture@example.invalid"])
    git!(root, ["config", "user.name", "Fixture"])
    # The fixture must not inherit the machine's global ignore rules (a global
    # `.DS_Store` exclude hid a committed trash file on one host).
    empty_excludes = Path.join(root, ".git/kogen-empty-excludes")
    File.write!(empty_excludes, "")
    git!(root, ["config", "core.excludesFile", empty_excludes])
    root
  end

  defp unique, do: "#{System.pid()}-#{System.unique_integer([:positive])}"

  defp git!(root, args) do
    assert {_output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end
end
