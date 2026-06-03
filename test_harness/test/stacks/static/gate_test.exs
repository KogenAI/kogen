defmodule CodegenTestHarness.Stacks.Static.GateTest do
  @moduledoc """
  Gate contract for the static stack.

  Asserts that `codegen-build --stack=static` exit 0 implies a committed,
  buildable, and renderable static site. Uses vite_react as the representative
  sub-stack (rich SPA; exercises npm build + headless render checks).
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 6_600_000

  @prompt ~s(Create a React app with Vite that shows a counter ) <>
            ~s(with data-testid="increment" and data-testid="count" elements.)

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  test "codegen-build exit 0 implies committed buildable static site", %{cwd: cwd} do
    output =
      Fixtures.run_codegen_build(cwd, @prompt,
        stack: "static",
        test_name: "gate_static_exit0"
      )

    assert File.exists?(Path.join(cwd, "package.json")),
           "expected package.json in #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_built_html_non_blank!(cwd, "dist/index.html")
    Assertions.assert_git_committed!(cwd)
    Assertions.assert_renders!(cwd, :static)

    Fixtures.bench_assertions_passed!("static", "gate_static_exit0")
  end
end
