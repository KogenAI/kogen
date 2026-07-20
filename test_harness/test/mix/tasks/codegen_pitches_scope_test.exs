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

  test "regression: default --json without --fleet-safe stays byte-identical (exactly 3 keys)",
       ctx do
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
    refute Map.has_key?(decoded, "dependency_bound")
  end

  test "--fleet-safe --json --lanes=N emits a 4th dependency_bound key", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/b.ex]\nblocks_on: [external-dep]\n---\n# b\n"
    )

    out =
      capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--lanes=2", "--json", "--fleet-safe"]) end)

    decoded = Jason.decode!(String.trim(out))

    assert Map.keys(decoded) |> Enum.sort() == [
             "dependency_bound",
             "global_hot",
             "lanes",
             "unrouted"
           ]

    assert decoded["dependency_bound"] == ["b"]
    refute "b" in List.flatten(decoded["lanes"])
    assert "a" in List.flatten(decoded["lanes"])
  end

  test "--fleet-safe --externally-referenced holds the named slug's component back", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "prereq.md"),
      "---\nstatus: SHAPED\nscope: [lib/prereq.ex]\n---\n# prereq\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    out =
      capture_io(fn ->
        Scope.run([
          "--cwd=#{ctx.tmp}",
          "--lanes=1",
          "--json",
          "--fleet-safe",
          "--externally-referenced=prereq"
        ])
      end)

    decoded = Jason.decode!(String.trim(out))

    assert decoded["dependency_bound"] == ["prereq"]
    refute "prereq" in List.flatten(decoded["lanes"])
    assert "a" in List.flatten(decoded["lanes"])
  end

  test "--fleet-safe without --lanes or --json exits 2, naming the constraint", ctx do
    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--fleet-safe"]))
    assert exit_val == {:shutdown, 2}
  end

  test "--fleet-safe with --lanes but without --json exits 2", ctx do
    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--lanes=1", "--fleet-safe"]))
    assert exit_val == {:shutdown, 2}
  end

  test "--externally-referenced without --fleet-safe exits 2", ctx do
    exit_val =
      catch_exit(
        Scope.run(["--cwd=#{ctx.tmp}", "--lanes=1", "--json", "--externally-referenced=x"])
      )

    assert exit_val == {:shutdown, 2}
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

  test "--check with a subsumed pair that declares split_subject: exits normally", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\nsplit_subject: starts the loop; wakes the fleet\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex, lib/b.ex]\n---\n# b\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--check"]) end)

    assert out =~ "COLLISIONS"
  end

  test "--check absent: SUBSUMED never triggers noise on the report path (regression)", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex, lib/b.ex]\n---\n# b\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}"]) end)

    refute out =~ "subsumed"
    refute out =~ "split_subject"
  end

  test "--lanes=N with a subsumed pair: normal lane/global-hot output, never SUBSUMED prose (regression)",
       ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex, lib/b.ex]\n---\n# b\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--lanes=2"]) end)

    assert out =~ "GLOBAL-HOT"
    refute out =~ "subsumed"
  end

  test "--json --lanes=N with a subsumed pair: decoded keys unchanged (regression)", ctx do
    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex, lib/b.ex]\n---\n# b\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--lanes=2", "--json"]) end)

    decoded = Jason.decode!(String.trim(out))

    assert Map.keys(decoded) |> Enum.sort() == ["global_hot", "lanes", "unrouted"]
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

  import ExUnit.CaptureIO

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

  test "--check with a subsumed pair and no split_subject: exits 2 naming both slugs", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex, lib/b.ex]\n---\n# b\n"
    )

    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--check"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "a"
    assert msg =~ "b"
    assert msg =~ "split_subject"
  end

  test "--check with UNROUTED and a subsumed pair reports UNROUTED first", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    File.write!(Path.join(ctx.ready_dir, "c.md"), "---\nstatus: SHAPED\n---\n# c\n")

    File.write!(
      Path.join(ctx.ready_dir, "a.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "b.md"),
      "---\nstatus: SHAPED\nscope: [lib/a.ex, lib/b.ex]\n---\n# b\n"
    )

    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--check"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "unrouted"
    refute msg =~ "split_subject"
  end

  test "--stamp-handoff-receipt without --check --slug exits 2 naming the constraint", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--stamp-handoff-receipt"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "--stamp-handoff-receipt requires --check --slug"
  end

  test "--stamp-handoff-receipt with --check but no --slug exits 2 naming the constraint", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    exit_val =
      catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--check", "--stamp-handoff-receipt"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "--stamp-handoff-receipt requires --check --slug"
  end

  test "--check --slug on a pitch with a missing counterpart exits 2 naming HANDOFF GAP", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    File.write!(
      Path.join(ctx.ready_dir, "source-a.md"),
      "---\nstatus: SHAPED\nscope: []\nhandoffs: [d1::source-a::owner-b::lib/x.ex]\n---\n# a\n"
    )

    exit_val =
      catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--check", "--slug=source-a"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "HANDOFF GAP d1"
    assert msg =~ "owner-b"
  end

  test "--check --slug with no matching pitch exits 2 naming the value", ctx do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    exit_val = catch_exit(Scope.run(["--cwd=#{ctx.tmp}", "--check", "--slug=nope"]))

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "nope"
  end

  test "--check --slug with a clean bilateral handoff passes with exit 0", ctx do
    record = "d1::source-a::owner-b::lib/x.ex"

    File.write!(
      Path.join(ctx.ready_dir, "source-a.md"),
      "---\nstatus: SHAPED\nscope: []\nhandoffs: [#{record}]\n---\n# a\n"
    )

    File.write!(
      Path.join(ctx.ready_dir, "owner-b.md"),
      "---\nstatus: SHAPED\nscope: [lib/x.ex]\nhandoffs: [#{record}]\n---\n# b\n"
    )

    out = capture_io(fn -> Scope.run(["--cwd=#{ctx.tmp}", "--check", "--slug=source-a"]) end)

    assert out =~ "COLLISIONS"
  end

  test "--stamp-handoff-receipt writes handoff_receipt: into draft participants only, " <>
         "leaving the ready pitch's copy of the record intact and clearable after the " <>
         "counterpart is removed to model fleet transfer",
       ctx do
    draft_dir = Path.join([ctx.tmp, "codegen", "pitches", "draft"])
    File.mkdir_p!(draft_dir)

    record = "d1::source-a::owner-b::lib/x.ex"

    source_path = Path.join(draft_dir, "source-a.md")
    owner_path = Path.join(draft_dir, "owner-b.md")

    File.write!(
      source_path,
      "---\nstatus: SHAPING\nscope: []\nhandoffs: [#{record}]\n---\n# a\n"
    )

    File.write!(
      owner_path,
      "---\nstatus: SHAPING\nscope: [lib/x.ex]\nhandoffs: [#{record}]\n---\n# b\n"
    )

    capture_io(fn ->
      Scope.run([
        "--cwd=#{ctx.tmp}",
        "--check",
        "--dir=draft",
        "--slug=source-a",
        "--stamp-handoff-receipt"
      ])
    end)

    source_content = File.read!(source_path)
    owner_content = File.read!(owner_path)

    assert source_content =~ ~r/handoff_receipt: sha256:[0-9a-f]{64}/
    assert owner_content =~ ~r/handoff_receipt: sha256:[0-9a-f]{64}/

    # Each participant's receipt is keyed by its OWN slug (see
    # LoopQueue.handoff_receipt/2) — a different slug means a different
    # digest even over the same record, so the two receipts are expected
    # to differ, not match.
    [_, source_receipt] = Regex.run(~r/handoff_receipt: (sha256:[0-9a-f]{64})/, source_content)
    [_, owner_receipt] = Regex.run(~r/handoff_receipt: (sha256:[0-9a-f]{64})/, owner_content)
    refute source_receipt == owner_receipt

    # Model fleet transfer: the owner participant is moved to ready/ then
    # its local draft copy is removed entirely (a ready pitch travels
    # alone). The now-promoted ready pitch's own stamped receipt must
    # still recompute and pass a focused check with the counterpart
    # fleet-absent — per-run temp build path avoids clobbering a
    # concurrent gate run's compiled beams.
    ready_dir = Path.join([ctx.tmp, "codegen", "pitches", "ready"])
    File.mkdir_p!(ready_dir)
    promoted_owner_path = Path.join(ready_dir, "owner-b.md")
    File.rename!(owner_path, promoted_owner_path)

    out =
      capture_io(fn ->
        Scope.run(["--cwd=#{ctx.tmp}", "--check", "--dir=ready", "--slug=owner-b"])
      end)

    assert out =~ "COLLISIONS"
  end

  test "--stamp-handoff-receipt refuses when a local participant is in building/", ctx do
    draft_dir = Path.join([ctx.tmp, "codegen", "pitches", "draft"])
    ready_dir = Path.join([ctx.tmp, "codegen", "pitches", "ready"])
    building_dir = Path.join([ctx.tmp, "codegen", "pitches", "building"])
    File.mkdir_p!(draft_dir)
    File.mkdir_p!(ready_dir)
    File.mkdir_p!(building_dir)

    record = "d1::source-a::owner-b::lib/x.ex"

    File.write!(
      Path.join(draft_dir, "source-a.md"),
      "---\nstatus: SHAPING\nscope: []\nhandoffs: [#{record}]\n---\n# a\n"
    )

    # owner-b resolves for reconciliation via its ready/ copy (claim_pitch!/2
    # has not yet renamed it away in this snapshot)...
    File.write!(
      Path.join(ready_dir, "owner-b.md"),
      "---\nstatus: SHAPED\nscope: [lib/x.ex]\nhandoffs: [#{record}]\n---\n# b\n"
    )

    # ...but a concurrent claim has ALSO landed a building/ copy — the
    # possession-controlled state the stamp step must refuse to write
    # around.
    File.write!(
      Path.join(building_dir, "owner-b.md"),
      "---\nstatus: SHAPED\nscope: [lib/x.ex]\nhandoffs: [#{record}]\n---\n# b\n"
    )

    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    exit_val =
      catch_exit(
        Scope.run([
          "--cwd=#{ctx.tmp}",
          "--check",
          "--dir=draft",
          "--slug=source-a",
          "--stamp-handoff-receipt"
        ])
      )

    assert exit_val == {:shutdown, 2}
    assert_receive {:mix_shell, :error, [msg]}
    assert msg =~ "building/"
    assert msg =~ "owner-b"

    refute File.read!(Path.join(draft_dir, "source-a.md")) =~ "handoff_receipt:"
  end
end
