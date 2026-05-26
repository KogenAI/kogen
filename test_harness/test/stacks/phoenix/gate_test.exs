defmodule CodegenTestHarness.Stacks.Phoenix.GateTest do
  @moduledoc """
  Gate contract for the phoenix stack.

  Asserts that `codegen-build --stack=phoenix` exit code reflects the
  dev-gate verdict: exit 0 means a committed, compilable app was produced.
  Mirrors the exit-code assertion shape of scaffold_test.exs.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 1_800_000

  @prompt ~s(Build a Phoenix LiveView todo app. The router MUST have ) <>
            ~s(live "/", TodoLive, :index. TodoLive MUST render a ) <>
            ~s(<form id="new-todo-form"> with an <input name="todo[title]"> ) <>
            ~s(and a <button data-testid="add-todo">.)

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  test "codegen-build exit 0 implies committed compilable phoenix app", %{cwd: cwd} do
    harness = Fixtures.harness()

    {output, exit_code} =
      System.cmd(
        Fixtures.codegen_build_path(),
        [
          "--harness=#{harness}",
          "--stack=phoenix",
          "--non-interactive",
          "--cwd=#{cwd}",
          @prompt
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "codegen-build failed (harness=#{harness}, exit=#{exit_code}):\n#{output}"

    assert File.exists?(Path.join(cwd, "mix.exs")),
           "expected mix.exs in #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_mix_compiles!(cwd)
    Assertions.assert_git_committed!(cwd)

    live_files =
      cwd
      |> Path.join("lib/*_web/live/**/*.ex")
      |> Path.wildcard()

    assert live_files != [],
           "expected at least one LiveView file under lib/*_web/live/ in #{cwd}"
  end
end
