defmodule CodegenTestHarness.Stacks.Static.SeedTest.Html do
  @moduledoc "html: second build from committed state produces fresh commit"
  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 1_800_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  @html_first_prompt ~s(Build a single-page landing site for a coffee shop called Brew & Co. ) <>
                       ~s(Include a <section id="hours"> with opening hours.)

  @html_change_prompt "Add a <section id=\"faq\"> with three <details> elements, " <>
                        "each containing a <summary> (the question) and a <p> (the answer)."

  test "html: second build from committed state produces fresh commit", %{cwd: cwd} do
    Fixtures.run_codegen_build(cwd, @html_first_prompt,
      stack: "static",
      test_name: "seed_static_html_first"
    )

    commits_after_first = Fixtures.count_commits!(cwd)
    assert commits_after_first >= 1, "First html build must produce at least one commit"

    Fixtures.run_codegen_build(cwd, @html_change_prompt,
      stack: "static",
      test_name: "seed_static_html_second"
    )

    Assertions.assert_new_commit_since!(cwd, commits_after_first)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_not_revert_head!(cwd)

    # Verify 2nd-prompt marker (faq section) survived the second build
    html_files = Path.wildcard(Path.join(cwd, "**/*.html"))
    faq_found = Enum.any?(html_files, fn path ->
      content = File.read!(path)
      String.contains?(content, ~s(id="faq")) and String.contains?(content, "<details")
    end)
    assert faq_found, "expected id=\"faq\" and <details in at least one HTML file after second build"

    Fixtures.bench_assertions_passed!("static", "seed_static_html_first")
    Fixtures.bench_assertions_passed!("static", "seed_static_html_second")
  end

end

defmodule CodegenTestHarness.Stacks.Static.SeedTest.Hugo do
  @moduledoc "hugo: second build from committed state produces fresh commit"
  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 1_800_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  @hugo_first_prompt ~s(Create a Hugo blog with three sample posts about gardening. ) <>
                       ~s(Each post must have a title and at least 50 words of body content.)

  @hugo_change_prompt ~s(Add a new blog post titled 'Spring Garden Tips' ) <>
                        ~s(with at least 100 words of body content about planting vegetables.)

  test "hugo: second build from committed state produces fresh commit", %{cwd: cwd} do
    Fixtures.run_codegen_build(cwd, @hugo_first_prompt,
      stack: "static",
      test_name: "seed_static_hugo_first"
    )

    commits_after_first = Fixtures.count_commits!(cwd)
    assert commits_after_first >= 1, "First hugo build must produce at least one commit"

    Fixtures.run_codegen_build(cwd, @hugo_change_prompt,
      stack: "static",
      test_name: "seed_static_hugo_second"
    )

    Assertions.assert_new_commit_since!(cwd, commits_after_first)
    Assertions.assert_hugo_builds!(cwd)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_not_revert_head!(cwd)

    # Verify 2nd-prompt marker (Spring Garden Tips) survived the second build
    all_files = [Path.join(cwd, "**/*.md"), Path.join(cwd, "**/*.html")] |> Enum.flat_map(&Path.wildcard/1)
    spring_found = Enum.any?(all_files, fn path -> File.read!(path) =~ ~r/spring garden tips/i end)
    assert spring_found, "expected 'Spring Garden Tips' in at least one file after second build"

    Fixtures.bench_assertions_passed!("static", "seed_static_hugo_first")
    Fixtures.bench_assertions_passed!("static", "seed_static_hugo_second")
  end

end

defmodule CodegenTestHarness.Stacks.Static.SeedTest.ViteReact do
  @moduledoc "vite-react: second build from committed state produces fresh commit"
  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 1_800_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  @react_first_prompt ~s(Create a React app with Vite that shows a counter ) <>
                        ~s(with data-testid="increment" and data-testid="count" elements.)

  @react_change_prompt "Add a <input data-testid=\"step\" type=\"number\"> to the counter app. " <>
                         "Each click of data-testid=\"increment\" MUST add the step value (default 1) to the count."

  test "vite-react: second build from committed state produces fresh commit", %{cwd: cwd} do
    Fixtures.run_codegen_build(cwd, @react_first_prompt,
      stack: "static",
      test_name: "seed_static_react_first"
    )

    commits_after_first = Fixtures.count_commits!(cwd)
    assert commits_after_first >= 1, "First vite-react build must produce at least one commit"

    Fixtures.run_codegen_build(cwd, @react_change_prompt,
      stack: "static",
      test_name: "seed_static_react_second"
    )

    Assertions.assert_new_commit_since!(cwd, commits_after_first)
    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_not_revert_head!(cwd)

    # Verify 2nd-prompt marker (step input) survived the second build
    jsx_files = [Path.join(cwd, "src/**/*.jsx"), Path.join(cwd, "src/**/*.tsx")] |> Enum.flat_map(&Path.wildcard/1)
    step_found = Enum.any?(jsx_files, fn path -> String.contains?(File.read!(path), ~s(data-testid="step")) end)
    assert step_found, "expected data-testid=\"step\" in at least one JSX/TSX file after second build"

    Fixtures.bench_assertions_passed!("static", "seed_static_react_first")
    Fixtures.bench_assertions_passed!("static", "seed_static_react_second")
  end

end

defmodule CodegenTestHarness.Stacks.Static.SeedTest.ViteVue do
  @moduledoc "vite-vue: second build from committed state produces fresh commit"
  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 1_800_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  @vue_first_prompt ~s(Create a Vue app with Vite that displays a color picker ) <>
                      ~s(with a hex output display element with data-testid="hex-output".)

  @vue_change_prompt ~s(Add a <button data-testid="reset"> that resets the hex output to #000000.)

  test "vite-vue: second build from committed state produces fresh commit", %{cwd: cwd} do
    Fixtures.run_codegen_build(cwd, @vue_first_prompt,
      stack: "static",
      test_name: "seed_static_vue_first"
    )

    commits_after_first = Fixtures.count_commits!(cwd)
    assert commits_after_first >= 1, "First vite-vue build must produce at least one commit"

    Fixtures.run_codegen_build(cwd, @vue_change_prompt,
      stack: "static",
      test_name: "seed_static_vue_second"
    )

    Assertions.assert_new_commit_since!(cwd, commits_after_first)
    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_not_revert_head!(cwd)

    # Verify 2nd-prompt marker (reset button) survived the second build
    vue_files = [Path.join(cwd, "src/**/*.vue"), Path.join(cwd, "src/**/*.js")] |> Enum.flat_map(&Path.wildcard/1)
    reset_found = Enum.any?(vue_files, fn path -> String.contains?(File.read!(path), ~s(data-testid="reset")) end)
    assert reset_found, "expected data-testid=\"reset\" in at least one Vue/JS file after second build"

    Fixtures.bench_assertions_passed!("static", "seed_static_vue_first")
    Fixtures.bench_assertions_passed!("static", "seed_static_vue_second")
  end

end

defmodule CodegenTestHarness.Stacks.Static.SeedTest.Multilingual do
  @moduledoc "multilingual: second build from committed state produces fresh commit"
  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 1_800_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  @multilingual_first_prompt ~s(Create a simple multilingual site with both English and Croatian versions. ) <>
                               ~s(Include a nav with language switcher links.)

  @multilingual_change_prompt ~s(Add an <a href="/en"> English link and <a href="/hr"> Croatian link ) <>
                                ~s(to the site navigation if not already present.)

  test "multilingual: second build from committed state produces fresh commit", %{cwd: cwd} do
    Fixtures.run_codegen_build(cwd, @multilingual_first_prompt,
      stack: "static",
      test_name: "seed_static_multilingual_first"
    )

    commits_after_first = Fixtures.count_commits!(cwd)
    assert commits_after_first >= 1, "First multilingual build must produce at least one commit"

    Fixtures.run_codegen_build(cwd, @multilingual_change_prompt,
      stack: "static",
      test_name: "seed_static_multilingual_second"
    )

    Assertions.assert_new_commit_since!(cwd, commits_after_first)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_not_revert_head!(cwd)

    # Verify 2nd-prompt markers (language links) survived the second build
    all_files = [Path.join(cwd, "**/*.html"), Path.join(cwd, "**/*.md")] |> Enum.flat_map(&Path.wildcard/1)
    en_found = Enum.any?(all_files, fn p -> File.read!(p) =~ ~r(href=.?/en) end)
    hr_found = Enum.any?(all_files, fn p -> File.read!(p) =~ ~r(href=.?/hr) end)
    assert en_found, "expected href=\"/en\" link in at least one file after second build"
    assert hr_found, "expected href=\"/hr\" link in at least one file after second build"

    Fixtures.bench_assertions_passed!("static", "seed_static_multilingual_first")
    Fixtures.bench_assertions_passed!("static", "seed_static_multilingual_second")
  end

end
