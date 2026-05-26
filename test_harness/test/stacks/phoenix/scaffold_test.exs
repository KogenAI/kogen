defmodule CodegenTestHarness.Stacks.Phoenix.ScaffoldTest do
  @moduledoc """
  Asserts that `codegen-build --stack=phoenix` provisions a compilable
  Phoenix app with a root LiveView route, for both `HARNESS=claude` and
  `HARNESS=pi`.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 1_800_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  test "codegen-build provisions phoenix app from empty dir", %{cwd: cwd} do
    assert String.starts_with?(cwd, System.tmp_dir!()),
           "tmp_dir leaked outside OS tmp: #{cwd}"

    harness = Fixtures.harness()

    {output, exit_code} =
      System.cmd(
        Fixtures.codegen_build_path(),
        [
          "--harness=#{harness}",
          "--stack=phoenix",
          "--non-interactive",
          "--cwd=#{cwd}",
          "make a single liveview at / that says hello world"
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "codegen-build failed (harness=#{harness}, exit=#{exit_code}):\n#{output}"

    assert File.exists?(Path.join(cwd, "mix.exs")),
           "expected mix.exs in #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_mix_compiles!(cwd)

    router_files = Path.wildcard(Path.join(cwd, "lib/*_web/router.ex"))
    assert router_files != [], "no router.ex found under lib/*_web/ in #{cwd}"
    [router | _] = router_files

    Assertions.assert_file_matches!(router, ~r/live\s+"\/"/)

    Assertions.assert_git_committed!(cwd)
  end
end
