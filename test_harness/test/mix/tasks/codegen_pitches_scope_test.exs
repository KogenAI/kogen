defmodule Mix.Tasks.Codegen.Pitches.ScopeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Codegen.Pitches.Scope

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "codegen_pitches_scope_test_#{:erlang.unique_integer([:positive])}"
      )

    ready_dir = Path.join([tmp, "codegen", "pitches", "ready"])
    File.mkdir_p!(ready_dir)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, ready_dir: ready_dir}
  end

  test "reports COLLISIONS with the shared path named", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/shared.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/shared.ex]\n---\n# b\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}"]) end)

    assert out =~ "COLLISIONS (1 pair share an edit surface)"
    assert out =~ "a x b"
    assert out =~ "lib/shared.ex"
  end

  test "reports DISJOINT for scoped pitches sharing no path", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/b.ex]\n---\n# b\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}"]) end)

    assert out =~ "DISJOINT (2 pitches, safe to run in parallel)"
    assert out =~ "a, b"
  end

  test "reports UNROUTED for a pitch with no scope: field", ctx do
    File.write!(Path.join(ctx.ready_dir, "a.md"), "---\nstatus: SHAPED\n---\n# a\n")

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}"]) end)

    assert out =~ "UNROUTED (1 pitch — no scope: field; a human must place these)"
    assert out =~ "a"
  end

  test "empty ready/ reports all-zero sections", ctx do
    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}"]) end)

    assert out =~ "COLLISIONS (0 pairs share an edit surface)"
    assert out =~ "DISJOINT (0 pitches)"
    assert out =~ "UNROUTED (0 pitches)"
  end

  test "--dir=draft scans the draft/ directory instead of ready/", ctx do
    draft_dir = Path.join([ctx.tmp, "codegen", "pitches", "draft"])
    File.mkdir_p!(draft_dir)

    File.write!(
      Path.join(draft_dir, "a.md"),
      "---\nstatus: SHAPING\nscope: [lib/a.ex]\n---\n# a\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--dir=draft"]) end)

    assert out =~ "DISJOINT (1 pitch, safe to run in parallel)"
    assert out =~ "a"
  end

  test "missing pitches dir prints a message and exits normally (not an error)", ctx do
    empty_cwd = Path.join(ctx.tmp, "nowhere")
    File.mkdir_p!(empty_cwd)

    out = capture_io(fn -> catch_exit(Scope.run(["--cwd=#{empty_cwd}"])) end)

    assert out =~ "no pitches in"
  end

  test "invalid --dir value exits 2 with an error naming the valid set", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--dir=bogus"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "bogus"
    assert msg =~ ~s(["ready", "draft", "shipped"])
  end

  test "invalid flag exits 2", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--nonsense=1"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "invalid flags"
  end

  test "scope: present but unparseable raises loud, naming the slug", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: not-a-list\n---\n# a\n"
    )

    assert_raise RuntimeError, ~r/a has a scope: value that is not a parseable/, fn ->
      capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}"]) end)
    end
  end
end
