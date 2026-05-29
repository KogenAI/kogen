defmodule CodegenTestHarness.Stacks.Static.ScaffoldTest.Hugo do
  @moduledoc "codegen-build provisions hugo blog from empty dir"
  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 6_600_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  test "codegen-build provisions hugo blog from empty dir", %{cwd: cwd} do
    output =
      Fixtures.run_codegen_build(
        cwd,
        "Create a Hugo blog with three sample posts about gardening. Each post must have a title and at least 50 words of body content.",
        stack: "static",
        test_name: "scaffold_static_hugo"
      )

    md_files = Path.wildcard(Path.join(cwd, "content/**/*.md"))

    assert md_files != [],
           "no content/**/*.md files found under #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_hugo_builds!(cwd)
    Assertions.assert_git_committed!(cwd)
    Fixtures.bench_assertions_passed!("static", "scaffold_static_hugo")
  end
end

defmodule CodegenTestHarness.Stacks.Static.ScaffoldTest.ViteReact do
  @moduledoc "codegen-build provisions vite-react app from empty dir"
  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 6_600_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  test "codegen-build provisions vite-react app from empty dir", %{cwd: cwd} do
    output =
      Fixtures.run_codegen_build(
        cwd,
        ~s(Create a React app with Vite that shows a counter with data-testid="increment" and data-testid="count" elements.),
        stack: "static",
        test_name: "scaffold_static_vite_react"
      )

    jsx_files =
      [Path.join(cwd, "src/**/*.jsx"), Path.join(cwd, "src/**/*.tsx")]
      |> Enum.flat_map(&Path.wildcard/1)

    assert jsx_files != [],
           "no src/**/*.{jsx,tsx} files found under #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_git_committed!(cwd)
    Fixtures.bench_assertions_passed!("static", "scaffold_static_vite_react")
  end
end

defmodule CodegenTestHarness.Stacks.Static.ScaffoldTest.ViteVue do
  @moduledoc "codegen-build provisions vite-vue app from empty dir"
  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 6_600_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  test "codegen-build provisions vite-vue app from empty dir", %{cwd: cwd} do
    output =
      Fixtures.run_codegen_build(
        cwd,
        ~s(Create a Vue app with Vite that displays a color picker with a hex output display element with data-testid="hex-output".),
        stack: "static",
        test_name: "scaffold_static_vite_vue"
      )

    vue_files = Path.wildcard(Path.join(cwd, "src/**/*.vue"))

    assert vue_files != [],
           "no src/**/*.vue files found under #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_git_committed!(cwd)
    Fixtures.bench_assertions_passed!("static", "scaffold_static_vite_vue")
  end
end

defmodule CodegenTestHarness.Stacks.Static.ScaffoldTest.Multilingual do
  @moduledoc "codegen-build provisions multilingual site from empty dir"
  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 6_600_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  test "codegen-build provisions multilingual site from empty dir", %{cwd: cwd} do
    output =
      Fixtures.run_codegen_build(
        cwd,
        "Create a simple multilingual site with both English and Croatian versions. Include a nav with language switcher links.",
        stack: "static",
        test_name: "scaffold_static_multilingual"
      )

    site_files =
      [Path.join(cwd, "**/*.html"), Path.join(cwd, "**/*.md")]
      |> Enum.flat_map(&Path.wildcard/1)

    assert site_files != [],
           "no **/*.{html,md} files found under #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_git_committed!(cwd)
    Fixtures.bench_assertions_passed!("static", "scaffold_static_multilingual")
  end
end
