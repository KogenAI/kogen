defmodule Mix.Tasks.Codegen.LoopTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Codegen.Loop

  setup do
    tmp = Path.join(System.tmp_dir!(), "codegen_loop_test_#{:erlang.unique_integer([:positive])}")
    ready_dir = Path.join([tmp, "codegen", "pitches", "ready"])
    building_dir = Path.join([tmp, "codegen", "pitches", "building"])
    File.mkdir_p!(ready_dir)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, ready_dir: ready_dir, building_dir: building_dir}
  end

  test "1: @-prefixed relative path resolves against cwd", ctx do
    body = "# Pitch: x\n"
    File.write!(Path.join(ctx.ready_dir, "x.md"), body)

    assert Loop.resolve_pitch("@codegen/pitches/ready/x.md", ctx.tmp) == body
  end

  test "2: bare-relative path (pi convention) resolves against cwd", ctx do
    body = "# Pitch: x\n"
    File.write!(Path.join(ctx.ready_dir, "x.md"), body)

    assert Loop.resolve_pitch("codegen/pitches/ready/x.md", ctx.tmp) == body
  end

  test "3: absolute @-prefixed path passes through, cwd ignored", ctx do
    body = "# Pitch: x\n"
    abs = Path.join(ctx.ready_dir, "x.md")
    File.write!(abs, body)

    assert Loop.resolve_pitch("@" <> abs, "/nonexistent/other/cwd") == body
  end

  test "4: not-found error message contains the resolved absolute path", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(original_shell) end)

    catch_exit(Loop.resolve_pitch("@codegen/pitches/ready/missing.md", ctx.tmp))

    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ Path.expand("codegen/pitches/ready/missing.md", ctx.tmp)
  end

  test "5: literal (non-file) prompt text passes through unchanged", ctx do
    assert Loop.resolve_pitch("just some prompt text", ctx.tmp) == "just some prompt text"
  end

  test "6: @-prefixed pitch with YAML frontmatter resolves to body only", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "x.md"),
      "---\nstatus: SHAPED\nblocks_on: []\n---\n# Pitch: x\n\nBody text.\n"
    )

    result = Loop.resolve_pitch("@codegen/pitches/ready/x.md", ctx.tmp)

    refute String.starts_with?(result, "---")
    assert result =~ "# Pitch: x"
    assert result =~ "Body text."
  end

  describe "maybe_ship_pitch/4" do
    test "happy-path move: ready file moves to shipped, content preserved", ctx do
      body = "# Pitch: foo\n"
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, body)

      shipped_path = Path.join([ctx.tmp, "codegen", "pitches", "shipped", "foo.md"])

      assert Loop.maybe_ship_pitch({:file, abs}, ctx.tmp) == :ok
      refute File.exists?(abs)
      assert File.exists?(shipped_path)
      assert File.read!(shipped_path) == body
    end

    test "idempotent rerun: source already shipped, no crash", ctx do
      shipped_dir = Path.join([ctx.tmp, "codegen", "pitches", "shipped"])
      File.mkdir_p!(shipped_dir)
      shipped_path = Path.join(shipped_dir, "foo.md")
      File.write!(shipped_path, "# Pitch: foo\n")

      missing_abs = Path.join(ctx.ready_dir, "foo.md")

      assert Loop.maybe_ship_pitch({:file, missing_abs}, ctx.tmp) == :ok
      assert File.exists?(shipped_path)
    end

    test "error-path invariant: pitch left in ready/ when maybe_ship_pitch is not called", ctx do
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      assert File.exists?(abs)
    end

    test "literal prompt text: no move, nothing created", ctx do
      shipped_dir = Path.join([ctx.tmp, "codegen", "pitches", "shipped"])

      assert Loop.maybe_ship_pitch(:literal, ctx.tmp) == :ok
      refute File.exists?(shipped_dir)
      assert File.ls!(ctx.ready_dir) == []
    end

    test "dirty working tree: retire is UNCONDITIONAL (pitch still ships), exits @dirty_tree_exit_code",
         ctx do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      System.cmd("git", ["init", "-q", ctx.tmp])
      System.cmd("git", ["-C", ctx.tmp, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", ctx.tmp, "config", "user.name", "Test"])
      System.cmd("git", ["-C", ctx.tmp, "config", "commit.gpgsign", "false"])

      gitkeep = Path.join(ctx.tmp, ".gitkeep")
      File.write!(gitkeep, "")
      System.cmd("git", ["-C", ctx.tmp, "add", "."])
      System.cmd("git", ["-C", ctx.tmp, "commit", "-q", "-m", "initial"])

      File.write!(Path.join(ctx.tmp, "stray.txt"), "uncommitted\n")

      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      # Deliverable 1's core proof: the retire is NOT hostage to a clean
      # tree — the pitch leaves ready/ and lands in shipped/ FIRST, then the
      # dirty-tree signal fires as a loud distinct exit, never a raise that
      # would strand the pitch back in ready/.
      assert catch_exit(Loop.maybe_ship_pitch({:file, abs}, ctx.tmp)) == {:shutdown, 4}

      refute File.exists?(abs)
      shipped_path = Path.join([ctx.tmp, "codegen", "pitches", "shipped", "foo.md"])
      assert File.exists?(shipped_path)

      assert_receive {:mix_shell, :error, [msg]}
      assert msg =~ "COMMITTED and RETIRED"
      assert msg =~ "stray.txt"
    end

    test "non-ready-dir file: no move, file stays at original path", ctx do
      elsewhere_dir = Path.join(ctx.tmp, "elsewhere")
      File.mkdir_p!(elsewhere_dir)
      abs = Path.join(elsewhere_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      shipped_dir = Path.join([ctx.tmp, "codegen", "pitches", "shipped"])

      assert Loop.maybe_ship_pitch({:file, abs}, ctx.tmp) == :ok
      assert File.exists?(abs)
      refute File.exists?(shipped_dir)
    end

    test "with before/after shas: records a git note and stamps frontmatter before the move",
         ctx do
      # The ready/ -> shipped/ mv itself creates an untracked shipped/ dir,
      # so the tree is dirty at ship time — the retire still runs
      # unconditionally (record_ship + mv), then the dirty-tree signal
      # fires as exit @dirty_tree_exit_code. See the "dirty working tree"
      # test above for the dedicated ordering proof; this test's focus is
      # the frontmatter stamp, which happens BEFORE the exit either way.
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      System.cmd("git", ["init", "-q", ctx.tmp])
      System.cmd("git", ["-C", ctx.tmp, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", ctx.tmp, "config", "user.name", "Test"])
      System.cmd("git", ["-C", ctx.tmp, "config", "commit.gpgsign", "false"])

      File.write!(Path.join(ctx.tmp, "a.txt"), "content\n")
      System.cmd("git", ["-C", ctx.tmp, "add", "."])
      System.cmd("git", ["-C", ctx.tmp, "commit", "-q", "-m", "initial"])
      {before_sha, 0} = System.cmd("git", ["-C", ctx.tmp, "rev-parse", "HEAD"])
      before_sha = String.trim(before_sha)

      body = "---\nstatus: ready\n---\n# Pitch: foo\n"
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, body)
      System.cmd("git", ["-C", ctx.tmp, "add", "."])
      System.cmd("git", ["-C", ctx.tmp, "commit", "-q", "-m", "add pitch"])
      {after_sha, 0} = System.cmd("git", ["-C", ctx.tmp, "rev-parse", "HEAD"])
      after_sha = String.trim(after_sha)

      assert catch_exit(Loop.maybe_ship_pitch({:file, abs}, ctx.tmp, before_sha, after_sha)) ==
               {:shutdown, 4}

      shipped_path = Path.join([ctx.tmp, "codegen", "pitches", "shipped", "foo.md"])
      refute File.exists?(abs)
      assert File.exists?(shipped_path)

      shipped_content = File.read!(shipped_path)
      assert shipped_content =~ "shipped_sha: #{after_sha}"
      assert shipped_content =~ "shipped_range: #{before_sha}..#{after_sha}"
    end

    test "nil after_sha (non-git / unborn cwd): ships without recording, no raise", ctx do
      body = "# Pitch: foo\n"
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, body)

      assert Loop.maybe_ship_pitch({:file, abs}, ctx.tmp, nil, nil) == :ok

      shipped_path = Path.join([ctx.tmp, "codegen", "pitches", "shipped", "foo.md"])
      assert File.read!(shipped_path) == body
    end
  end

  describe "claim_pitch!/2 — possession by rename" do
    test "moves ready/<slug>.md to building/<slug>.md and returns the new path", ctx do
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      assert Loop.claim_pitch!({:file, abs}, ctx.tmp) ==
               {:file, Path.join([ctx.tmp, "codegen", "pitches", "building", "foo.md"])}

      refute File.exists?(abs)
      assert File.exists?(Path.join([ctx.tmp, "codegen", "pitches", "building", "foo.md"]))
    end

    test "a second claim on the same slug refuses (ENOENT — already claimed)", ctx do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      assert {:file, _building_abs} = Loop.claim_pitch!({:file, abs}, ctx.tmp)

      # second claim: source is already gone from ready/ (the same abs path
      # is passed, mirroring a second builder racing on the same slug)
      assert catch_exit(Loop.claim_pitch!({:file, abs}, ctx.tmp)) == {:shutdown, 2}

      assert_receive {:mix_shell, :error, [msg]}
      assert msg =~ "already claimed"
      assert msg =~ "foo"
    end

    test "literal source passes through unchanged, nothing claimed", ctx do
      assert Loop.claim_pitch!(:literal, ctx.tmp) == :literal
    end

    test "a file outside ready/ passes through unchanged", ctx do
      elsewhere = Path.join(ctx.tmp, "elsewhere")
      File.mkdir_p!(elsewhere)
      abs = Path.join(elsewhere, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      assert Loop.claim_pitch!({:file, abs}, ctx.tmp) == {:file, abs}
      assert File.exists?(abs)
    end
  end

  describe "restore_claim/2 — diff-failure restores building/ back to ready/" do
    test "moves building/<slug>.md back to ready/<slug>.md", ctx do
      abs = Path.join(ctx.ready_dir, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      {:file, building_abs} = Loop.claim_pitch!({:file, abs}, ctx.tmp)

      assert Loop.restore_claim({:file, building_abs}, ctx.tmp) == :ok

      refute File.exists?(building_abs)
      assert File.exists?(abs)
      assert File.read!(abs) == "# Pitch: foo\n"
    end

    test "literal source: no-op", ctx do
      assert Loop.restore_claim(:literal, ctx.tmp) == :ok
    end

    test "a file not in building/: no-op, no crash", ctx do
      elsewhere = Path.join(ctx.tmp, "elsewhere")
      File.mkdir_p!(elsewhere)
      abs = Path.join(elsewhere, "foo.md")
      File.write!(abs, "# Pitch: foo\n")

      assert Loop.restore_claim({:file, abs}, ctx.tmp) == :ok
      assert File.exists?(abs)
    end
  end

  describe "maybe_ship_pitch/4 — building/ source (the normal claimed path)" do
    test "ships a pitch whose source is building/<slug>.md into shipped/", ctx do
      building_dir = Path.join([ctx.tmp, "codegen", "pitches", "building"])
      File.mkdir_p!(building_dir)
      abs = Path.join(building_dir, "foo.md")
      body = "# Pitch: foo\n"
      File.write!(abs, body)

      assert Loop.maybe_ship_pitch({:file, abs}, ctx.tmp) == :ok

      refute File.exists?(abs)
      shipped_path = Path.join([ctx.tmp, "codegen", "pitches", "shipped", "foo.md"])
      assert File.exists?(shipped_path)
      assert File.read!(shipped_path) == body
    end
  end

  describe "verify_commit_landed/2 — solo ship-gate floor" do
    defp init_git_repo!(cwd) do
      System.cmd("git", ["init", "-q", cwd])
      System.cmd("git", ["-C", cwd, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", cwd, "config", "user.name", "Test"])
      System.cmd("git", ["-C", cwd, "config", "commit.gpgsign", "false"])
    end

    defp commit!(cwd, filename, message) do
      File.write!(Path.join(cwd, filename), "content\n")
      System.cmd("git", ["-C", cwd, "add", "."])
      System.cmd("git", ["-C", cwd, "commit", "-q", "-m", message])
    end

    test "HEAD unmoved: raises-shaped error, no commit landed this cycle", ctx do
      init_git_repo!(ctx.tmp)
      commit!(ctx.tmp, "a.txt", "initial")

      before = Loop.git_head(ctx.tmp)

      assert {:error, reason} = Loop.verify_commit_landed(before, ctx.tmp)
      assert reason =~ "HEAD did not advance"
    end

    test "HEAD advanced (non-orphaning): passes", ctx do
      init_git_repo!(ctx.tmp)
      commit!(ctx.tmp, "a.txt", "initial")

      before = Loop.git_head(ctx.tmp)

      commit!(ctx.tmp, "b.txt", "second")

      assert {:ok, after_sha} = Loop.verify_commit_landed(before, ctx.tmp)
      assert is_binary(after_sha)
    end

    test "orphaning HEAD (history rewritten, not extended): raises-shaped error", ctx do
      init_git_repo!(ctx.tmp)
      commit!(ctx.tmp, "a.txt", "initial")
      commit!(ctx.tmp, "b.txt", "second")

      before = Loop.git_head(ctx.tmp)

      # Rewrite history: reset to an orphan commit unrelated to `before`.
      System.cmd("git", ["-C", ctx.tmp, "checkout", "--orphan", "rewritten"])
      File.write!(Path.join(ctx.tmp, "c.txt"), "content\n")
      System.cmd("git", ["-C", ctx.tmp, "add", "."])
      System.cmd("git", ["-C", ctx.tmp, "commit", "-q", "-m", "rewritten history"])

      assert {:error, reason} = Loop.verify_commit_landed(before, ctx.tmp)
      assert reason =~ "not an ancestor"
    end

    test "non-git cwd / unborn HEAD: fails open", ctx do
      before = Loop.git_head(ctx.tmp)

      assert before == :unborn
      assert Loop.verify_commit_landed(before, ctx.tmp) == {:ok, nil}
    end
  end

  describe "run_loop_catching_infra_abort/1 — the sole producer of exit code 3" do
    test "OrchestrationLoop.run raising InfraAbort exits {:shutdown, 3} naming the fault" do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)

      raising_run_fn = fn ->
        raise CodegenTestHarness.InfraAbort, "gate: poisoned DB state no edit can fix"
      end

      assert catch_exit(Loop.run_loop_catching_infra_abort(raising_run_fn)) ==
               {:shutdown, 3}

      assert_receive {:mix_shell, :error, [msg]}
      assert msg =~ "poisoned DB state no edit can fix"
    end

    test "a normal :ok result passes through untouched (no exit, no rescue triggered)" do
      assert Loop.run_loop_catching_infra_abort(fn -> :ok end) == :ok
    end

    test "a normal {:error, reason} result passes through untouched (not converted to infra exit)" do
      assert Loop.run_loop_catching_infra_abort(fn -> {:error, "gate verdict=failed"} end) ==
               {:error, "gate verdict=failed"}
    end

    test "a DIFFERENT raised exception is NOT swallowed — only InfraAbort is caught" do
      assert_raise RuntimeError, "unrelated crash", fn ->
        Loop.run_loop_catching_infra_abort(fn -> raise "unrelated crash" end)
      end
    end
  end
end
