defmodule Mix.Tasks.Codegen.Pitches.ScopeTest do
  # async: false: these tests assert on captured stdout via
  # Mix.shell().info/.error, which implicitly depends on the ambient
  # Mix.shell/1 default (Mix.Shell.IO) not being flipped concurrently.
  # The ScopeShellTest sibling module below explicitly swaps in
  # Mix.Shell.Process (process-global state) — running both async: true
  # at once races: an in-flight ScopeTest capture_io assertion here can
  # observe zero printed output when a concurrent ScopeShellTest test
  # has temporarily flipped the global shell to Mix.Shell.Process.
  use ExUnit.Case, async: false

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

  test "scope: present but unparseable raises loud, naming the slug", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: not-a-list\n---\n# a\n"
    )

    assert_raise RuntimeError, ~r/a has a scope: value that is not a parseable/, fn ->
      capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}"]) end)
    end
  end

  # (Mix.shell()-mutating tests live in the async: false
  # ScopeShellTest sibling module below to avoid cross-test races.)

  test "without --lanes, output is byte-identical to the pre-lanes report (UNROUTED, no LANE/GLOBAL-HOT)",
       ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}"]) end)

    refute out =~ "LANE"
    refute out =~ "GLOBAL-HOT"
    assert out =~ "UNROUTED (0 pitches)"
  end

  test "--lanes=N prints LANE sections, GLOBAL-HOT, and UNROUTED (no bare DISJOINT-only UNROUTED path)",
       ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/b.ex]\n---\n# b\n"
    )

    File.write!(Path.join(ctx.ready_dir, "c.md"), "---\nstatus: SHAPED\n---\n# c\n")

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--lanes=2"]) end)

    assert out =~ "LANE 1"
    assert out =~ "LANE 2"
    assert out =~ "GLOBAL-HOT (0 pitches)"
    assert out =~ "UNROUTED (1 pitch — no scope: field; a human must place these)"
    assert out =~ "c"
  end

  test "--lanes exceeding routable pitch count prints fewer lanes and says so", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--lanes=3"]) end)

    assert out =~ "3 lanes requested; only 1 routable pitch — printing 1"
    assert out =~ "LANE 1"
    refute out =~ "LANE 2"
    refute out =~ "LANE 3"
  end

  test "--check absent: output/exit are byte-identical to today (regression)", ctx do
    File.write!(Path.join(ctx.ready_dir, "a.md"), "---\nstatus: SHAPED\n---\n# a\n")

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}"]) end)

    assert out =~ "UNROUTED (1 pitch — no scope: field; a human must place these)"
    assert out =~ "COLLISIONS (0 pairs share an edit surface)"
    assert out =~ "DISJOINT (0 pitches)"
  end

  test "--check with scope: [] (explicit empty list) is DISJOINT, not UNROUTED, and passes",
       ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: []\n---\n# a\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--check"]) end)

    assert out =~ "DISJOINT (1 pitch, safe to run in parallel)"
    assert out =~ "UNROUTED (0 pitches)"
  end

  test "--check with all pitches routed exits normally (no raise)", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--check"]) end)

    assert out =~ "DISJOINT (1 pitch, safe to run in parallel)"
  end

  test "GLOBAL-HOT pitch is listed and never appears inside a LANE section", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "hot.md"),
      "---\nstatus: SHAPED\nscope: [lib/x.ex, lib/y.ex]\n---\n# hot\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/x.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/y.ex]\n---\n# b\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--lanes=2"]) end)

    assert out =~ "GLOBAL-HOT (1 pitch — collides with every lane; build alone)"
    assert out =~ "hot"

    [_before, after_global_hot] = String.split(out, "GLOBAL-HOT", parts: 2)
    refute after_global_hot =~ ~r/LANE \d/
  end

  test "--json --lanes=N emits Jason-decodable JSON with lanes/global_hot/unrouted keys", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/b.ex]\n---\n# b\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--lanes=2", "--json"]) end)

    decoded = Jason.decode!(String.trim(out))

    assert Map.keys(decoded) |> Enum.sort() == ["global_hot", "lanes", "unrouted"]
    assert is_list(decoded["lanes"])
    assert length(decoded["lanes"]) == 2
    assert decoded["global_hot"] == []
    assert decoded["unrouted"] == []
    assert decoded["lanes"] |> List.flatten() |> Enum.sort() == ["a", "b"]
  end

  test "--json --lanes=N emits no ANSI escapes and no LANE/COLLISIONS prose", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--lanes=1", "--json"]) end)

    refute out =~ "\e["
    refute out =~ "LANE"
    refute out =~ "COLLISIONS"
    refute out =~ "DISJOINT"
  end

  test "--json: a GLOBAL-HOT slug lands in global_hot, never in a lane", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "hot.md"),
      "---\nstatus: SHAPED\nscope: [lib/x.ex, lib/y.ex]\n---\n# hot\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/x.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/y.ex]\n---\n# b\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--lanes=2", "--json"]) end)

    decoded = Jason.decode!(String.trim(out))

    assert decoded["global_hot"] == ["hot"]
    refute "hot" in List.flatten(decoded["lanes"])
  end

  test "--json: an unrouted slug lands in unrouted, never in a lane", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    File.write!(Path.join(ctx.ready_dir, "c.md"), "---\nstatus: SHAPED\n---\n# c\n")

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--lanes=1", "--json"]) end)

    decoded = Jason.decode!(String.trim(out))

    assert decoded["unrouted"] == ["c"]
    refute "c" in List.flatten(decoded["lanes"])
  end
end

# Mix.shell/1 mutates process-global state. Tests that swap in
# Mix.Shell.Process to assert_receive an error message race against every
# OTHER async: true test in this file that also calls Mix.shell(...) — see
# the async: false sibling-module race-pitfall in context/development.md.
# Isolated here, async: false, so assert_receive never observes a message
# sent by a concurrently-running peer test.
defmodule Mix.Tasks.Codegen.Pitches.ScopeShellTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Codegen.Pitches.Scope

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "codegen_pitches_scope_shell_test_#{:erlang.unique_integer([:positive])}"
      )

    ready_dir = Path.join([tmp, "codegen", "pitches", "ready"])
    File.mkdir_p!(ready_dir)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, ready_dir: ready_dir}
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

  test "--lanes=0 exits 2 naming the invalid value", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--lanes=0"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "positive integer"
    assert msg =~ "0"
  end

  test "--lanes=not-a-number exits 2 naming the invalid value", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--lanes=abc"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "positive integer"
    assert msg =~ "abc"
  end

  test "--check with an unrouted pitch exits 2 naming the slug", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    File.write!(Path.join(ctx.ready_dir, "a.md"), "---\nstatus: SHAPED\n---\n# a\n")

    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--check"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "unrouted"
    assert msg =~ "a"
  end

  test "--json without --lanes exits 2 naming the constraint", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--json"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "--json requires --lanes"
  end
end
