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
end
