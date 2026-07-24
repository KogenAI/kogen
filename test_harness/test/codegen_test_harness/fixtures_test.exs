defmodule CodegenTestHarness.FixturesTest do
  @moduledoc """
  Hermetic tests for `CodegenTestHarness.Fixtures.rm_rf_resilient/1` — the
  retrying, non-raising teardown helper used by `isolated_tmp_dir/1`'s
  `on_exit` cleanup.

  These tests are fast and deterministic — no LLM, no Playwright, no server.
  They exercise the retry/give-up behavior directly rather than reproducing
  the real dev-server file race.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Fixtures

  describe "isolated_tmp_dir/1 phoenix baseline" do
    @tag :slow
    @tag timeout: 300_000
    test "returns a clean generated downstream app before the build cycle starts" do
      cwd = Fixtures.isolated_tmp_dir(stack: :phoenix)

      {status, 0} =
        System.cmd("git", ["status", "--porcelain"],
          cd: cwd,
          env: [],
          stderr_to_stdout: true
        )

      assert status == "",
             "expected generated phoenix app to be clean before codegen-build, got:\n#{status}"
    end
  end

  describe "prepare_codegen_build_baseline!/2" do
    test "commits static integrate output before the build cycle starts" do
      cwd = Fixtures.isolated_tmp_dir()

      Fixtures.prepare_codegen_build_baseline!(cwd, "static")

      {status, 0} =
        System.cmd("git", ["status", "--porcelain"],
          cd: cwd,
          env: [],
          stderr_to_stdout: true
        )

      assert status == "",
             "expected static app baseline to be clean before codegen-build, got:\n#{status}"
    end
  end

  describe "rm_rf_resilient/1 happy path" do
    test "removes a directory tree that is not being contended" do
      path =
        Path.join(
          System.tmp_dir!(),
          "fixtures_test_happy_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(path, "nested"))
      File.write!(Path.join(path, "nested/file.txt"), "hello")

      assert :ok = Fixtures.rm_rf_resilient(path)
      refute File.exists?(path)
    end

    test "returns :ok for a path that does not exist" do
      path =
        Path.join(
          System.tmp_dir!(),
          "fixtures_test_missing_#{:erlang.unique_integer([:positive])}"
        )

      refute File.exists?(path)
      assert :ok = Fixtures.rm_rf_resilient(path)
    end
  end

  describe "rm_rf_resilient/1 give-up path" do
    test "recovers once a transient failure clears, without raising" do
      path =
        Path.join(
          System.tmp_dir!(),
          "fixtures_test_race_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(path, "sub"))
      File.write!(Path.join(path, "sub/file.txt"), "x")

      # Force File.rm_rf/1 to observe a transient EEXIST (read-only parent
      # dir), mirroring the brief post-group-kill flush window from a
      # Phoenix dev server's watcher — then let it clear before the retry
      # budget (5 attempts x 200ms) is exhausted.
      File.chmod!(path, 0o555)

      spawn(fn ->
        Process.sleep(150)
        File.chmod!(path, 0o755)
      end)

      assert :ok = Fixtures.rm_rf_resilient(path)
      refute File.exists?(path)
    end

    test "gives up quietly (no raise) when the failure never clears" do
      path =
        Path.join(
          System.tmp_dir!(),
          "fixtures_test_stuck_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(path, "sub"))
      File.write!(Path.join(path, "sub/file.txt"), "x")

      # read-only parent dir: File.rm_rf/1 will keep returning {:error,
      # :eexist, path} on every attempt, forcing the give-up branch.
      File.chmod!(path, 0o555)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert :ok = Fixtures.rm_rf_resilient(path)
        end)

      assert stderr =~ "rm_rf_resilient: giving up cleaning up"

      # cleanup: restore perms so the real tmp dir can be reaped
      File.chmod!(path, 0o755)
      File.rm_rf!(path)
    end
  end
end
