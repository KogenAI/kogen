defmodule CodegenTestHarness.BornDeadDetectorTest do
  # Verifies CodegenTestHarness.BornDeadDetector.check/2 — the fail-closed
  # pre-commit backstop behind "a build implements the WHOLE pitch". Both
  # loop floors (solo assert_work_produced!/2, drain born_dead_fn) call
  # into this same check/2.
  use ExUnit.Case, async: true

  alias CodegenTestHarness.BornDeadDetector

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "born_dead_detector_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp git!(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  defp init_repo!(dir) do
    {_out, 0} = git!(dir, ["init", "-q"])
    {_out, 0} = git!(dir, ["config", "user.email", "t@example.com"])
    {_out, 0} = git!(dir, ["config", "user.name", "T"])
  end

  defp commit_all!(dir, msg) do
    {_out, 0} = git!(dir, ["add", "-A"])
    {_out, 0} = git!(dir, ["commit", "-q", "-m", msg])
  end

  defp head!(dir) do
    {out, 0} = git!(dir, ["rev-parse", "HEAD"])
    String.trim(out)
  end

  describe "check/2" do
    test "base_sha nil (no known cycle base) returns :ok" do
      assert BornDeadDetector.check("/tmp/whatever", nil) == :ok
    end

    test "non-git / non-existent cwd returns :ok (fail-open on absent tree)" do
      assert BornDeadDetector.check(
               "/tmp/does-not-exist-#{:erlang.unique_integer([:positive])}",
               "abc123"
             ) == :ok
    end

    test "new module WITH a live caller elsewhere in the tree ships clean", %{dir: dir} do
      init_repo!(dir)
      File.write!(Path.join(dir, "seed.ex"), "defmodule Seed do\n  def go, do: :ok\nend\n")

      # pre-existing caller, committed BEFORE the cycle base — only the new
      # module itself is introduced by this cycle's diff.
      File.write!(
        Path.join(dir, "caller.ex"),
        "defmodule Caller do\n  def go, do: :ok\nend\n"
      )

      commit_all!(dir, "seed")
      base = head!(dir)

      lib_dir = Path.join(dir, "lib")
      File.mkdir_p!(lib_dir)

      File.write!(
        Path.join(lib_dir, "helper_thing.ex"),
        "defmodule HelperThing do\n  def run, do: :ok\nend\n"
      )

      # wire the pre-existing caller to reference the new module's basename
      File.write!(
        Path.join(dir, "caller.ex"),
        "defmodule Caller do\n  def go, do: HelperThing.run()\nend\n"
      )

      commit_all!(dir, "add helper_thing, wire caller")

      assert BornDeadDetector.check(dir, base) == :ok
    end

    test "new module with ZERO live caller and ZERO registration is refused (born-dead)", %{
      dir: dir
    } do
      init_repo!(dir)
      File.write!(Path.join(dir, "seed.ex"), "defmodule Seed do\n  def go, do: :ok\nend\n")
      commit_all!(dir, "seed")
      base = head!(dir)

      lib_dir = Path.join(dir, "lib")
      File.mkdir_p!(lib_dir)

      File.write!(
        Path.join(lib_dir, "orphan_module.ex"),
        "defmodule OrphanModule do\n  def run, do: :ok\nend\n"
      )

      commit_all!(dir, "add orphan_module, uncalled")

      assert {:error, reason} = BornDeadDetector.check(dir, base)
      assert reason =~ "orphan_module"
    end

    test "defer-marker on an added line is refused even when the module has a caller", %{
      dir: dir
    } do
      init_repo!(dir)
      File.write!(Path.join(dir, "seed.ex"), "defmodule Seed do\n  def go, do: :ok\nend\n")
      commit_all!(dir, "seed")
      base = head!(dir)

      File.write!(
        Path.join(dir, "note.md"),
        "# Notes\n\nFuture migration (not yet wired) — will connect this later.\n"
      )

      commit_all!(dir, "add deferred note")

      assert {:error, reason} = BornDeadDetector.check(dir, base)
      assert reason =~ "defer marker"
    end

    test "new entity registered via a manifest reference ships clean (escape valve)", %{
      dir: dir
    } do
      init_repo!(dir)
      File.write!(Path.join(dir, "seed.ex"), "defmodule Seed do\n  def go, do: :ok\nend\n")
      commit_all!(dir, "seed")
      base = head!(dir)

      harness_dir = Path.join([dir, "harnesses", "claude"])
      File.mkdir_p!(harness_dir)
      File.write!(Path.join(harness_dir, "manifest.yaml"), "launchers:\n  - status_cli\n")

      File.write!(
        Path.join(dir, "status_cli.ex"),
        "defmodule StatusCli do\n  # registered via manifest launchers: — no in-repo caller needed\n  def main(_args), do: :ok\nend\n"
      )

      commit_all!(dir, "add status_cli, registered via manifest")

      assert BornDeadDetector.check(dir, base) == :ok
    end

    test "modifying an existing file (not introducing a new one) never trips born-dead", %{
      dir: dir
    } do
      init_repo!(dir)

      File.write!(
        Path.join(dir, "existing.ex"),
        "defmodule Existing do\n  def go, do: :ok\nend\n"
      )

      commit_all!(dir, "seed")
      base = head!(dir)

      File.write!(
        Path.join(dir, "existing.ex"),
        "defmodule Existing do\n  def go, do: :ok\n  def go2, do: :ok\nend\n"
      )

      commit_all!(dir, "modify existing")

      assert BornDeadDetector.check(dir, base) == :ok
    end

    test "a new *_test.exs file alone is never treated as a born-dead production entity", %{
      dir: dir
    } do
      init_repo!(dir)
      File.write!(Path.join(dir, "seed.ex"), "defmodule Seed do\n  def go, do: :ok\nend\n")
      commit_all!(dir, "seed")
      base = head!(dir)

      test_dir = Path.join(dir, "test")
      File.mkdir_p!(test_dir)

      File.write!(
        Path.join(test_dir, "seed_test.exs"),
        "defmodule SeedTest do\n  use ExUnit.Case\n  test \"go\", do: assert Seed.go() == :ok\nend\n"
      )

      commit_all!(dir, "add seed_test")

      assert BornDeadDetector.check(dir, base) == :ok
    end
  end
end
