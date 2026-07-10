defmodule Mix.Tasks.Codegen.LoopTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Codegen.Loop

  setup do
    tmp = Path.join(System.tmp_dir!(), "codegen_loop_test_#{:erlang.unique_integer([:positive])}")
    ready_dir = Path.join([tmp, "codegen", "pitches", "ready"])
    File.mkdir_p!(ready_dir)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, ready_dir: ready_dir}
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

  describe "maybe_ship_pitch/2" do
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

    test "dirty working tree: raises and does not move the pitch", ctx do
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

      assert_raise RuntimeError, ~r/working tree not clean/, fn ->
        Loop.maybe_ship_pitch({:file, abs}, ctx.tmp)
      end

      shipped_path = Path.join([ctx.tmp, "codegen", "pitches", "shipped", "foo.md"])
      refute File.exists?(shipped_path)
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
  end
end
