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
  @moduletag timeout: 6_600_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir(stack: :phoenix)}
  end

  test "codegen-build provisions phoenix app from empty dir", %{cwd: cwd} do
    assert String.starts_with?(cwd, System.tmp_dir!()),
           "tmp_dir leaked outside OS tmp: #{cwd}"

    output =
      Fixtures.run_codegen_build(cwd, "make a single liveview at / that says hello world",
        stack: "phoenix",
        test_name: "scaffold_provisions_phoenix"
      )

    assert File.exists?(Path.join(cwd, "mix.exs")),
           "expected mix.exs in #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_mix_compiles!(cwd)
    Assertions.assert_assets_deploy!(cwd)
    Assertions.assert_generated_tests_pass!(cwd)

    router_files = Path.wildcard(Path.join(cwd, "lib/*_web/router.ex"))
    assert router_files != [], "no router.ex found under lib/*_web/ in #{cwd}"
    [router | _] = router_files

    Assertions.assert_router_root_route_replaced!(router)

    Assertions.assert_git_committed!(cwd)

    # codegen-scaffold produces these files for every phoenix app
    assert File.exists?(Path.join(cwd, "PROJECT_CONTEXT.md")),
           "expected PROJECT_CONTEXT.md in #{cwd}"

    assert File.exists?(Path.join(cwd, "restart_server.sh")),
           "expected restart_server.sh in #{cwd}"

    assert File.exists?(Path.join(cwd, "codegen/usage_rules_INDEX.md")),
           "expected codegen/usage_rules_INDEX.md in #{cwd}"

    Assertions.assert_usage_rules_index_no_dangling_citations!(cwd)

    # working tree must be clean after codegen-scaffold commit
    {porcelain, 0} =
      System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true, env: [])

    untracked_committed =
      porcelain
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "??"))

    assert untracked_committed == [],
           "expected clean committed tree in #{cwd}, got:\n#{porcelain}"

    Assertions.assert_renders!(cwd, :phoenix)
    Fixtures.bench_assertions_passed!("phoenix", "scaffold_provisions_phoenix")
  end
end
