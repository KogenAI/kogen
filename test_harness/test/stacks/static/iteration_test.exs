defmodule CodegenTestHarness.Stacks.Static.IterationTest.HtmlChangeRequest do
  @moduledoc "html change-request: new commit with faq markers"
  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 12_000_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  @html_first_prompt ~s(Build a single-page landing site for a coffee shop called Brew & Co. ) <>
                       ~s(Include a <section id="hours"> with opening hours.)

  @html_change_prompt "Add a <section id=\"faq\"> with three <details> elements, " <>
                        "each containing a <summary> (the question) and a <p> (the answer)."

  test "html change-request lands new commit with faq markers", %{cwd: cwd} do
    {commits_before, commits_after} =
      Fixtures.change_request(cwd, @html_first_prompt, @html_change_prompt,
        stack: "static",
        test_name: "iteration_static_html_faq"
      )

    assert commits_after > commits_before,
           "html change request must produce a new commit. Before: #{commits_before}, after: #{commits_after}"

    html_files = Path.wildcard(Path.join(cwd, "**/*.html"))

    faq_found =
      Enum.any?(html_files, fn path ->
        content = File.read!(path)
        String.contains?(content, ~s(id="faq")) and String.contains?(content, "<details")
      end)

    assert faq_found,
           "expected id=\"faq\" and <details in at least one HTML file under #{cwd}. " <>
             "Files: #{inspect(html_files)}"

    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_git_committed!(cwd)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_commit_subject_length!(cwd)
    Assertions.assert_not_revert_head!(cwd)
    Fixtures.bench_assertions_passed!("static", "iteration_static_html_faq_scaffold")
    Fixtures.bench_assertions_passed!("static", "iteration_static_html_faq_change")
  end
end

defmodule CodegenTestHarness.Stacks.Static.IterationTest.HugoChangeRequest do
  @moduledoc "hugo change-request: new commit with new post"
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

  test "hugo change-request lands new commit with new post", %{cwd: cwd} do
    {commits_before, commits_after} =
      Fixtures.change_request(cwd, @hugo_first_prompt, @hugo_change_prompt,
        stack: "static",
        test_name: "iteration_static_hugo_spring"
      )

    assert commits_after > commits_before,
           "hugo change request must produce a new commit. Before: #{commits_before}, after: #{commits_after}"

    all_files =
      [Path.join(cwd, "**/*.md"), Path.join(cwd, "**/*.html")]
      |> Enum.flat_map(&Path.wildcard/1)

    found =
      Enum.any?(all_files, fn path ->
        File.read!(path) =~ ~r/spring garden tips/i
      end)

    assert found,
           "Expected 'Spring Garden Tips' in at least one file under #{cwd}. " <>
             "Files searched: #{length(all_files)}"

    Assertions.assert_hugo_builds!(cwd)
    Assertions.assert_git_committed!(cwd)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_commit_subject_length!(cwd)
    Assertions.assert_not_revert_head!(cwd)
    Fixtures.bench_assertions_passed!("static", "iteration_static_hugo_spring_scaffold")
    Fixtures.bench_assertions_passed!("static", "iteration_static_hugo_spring_change")
  end
end

defmodule CodegenTestHarness.Stacks.Static.IterationTest.ReactChangeRequest do
  @moduledoc "react (vite) change-request: new commit with step input marker"
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

  test "react change-request lands new commit with step input marker", %{cwd: cwd} do
    {commits_before, commits_after} =
      Fixtures.change_request(cwd, @react_first_prompt, @react_change_prompt,
        stack: "static",
        test_name: "iteration_static_react_step"
      )

    assert commits_after > commits_before,
           "react change request must produce a new commit. Before: #{commits_before}, after: #{commits_after}"

    jsx_files =
      [Path.join(cwd, "src/**/*.jsx"), Path.join(cwd, "src/**/*.tsx")]
      |> Enum.flat_map(&Path.wildcard/1)

    found =
      Enum.any?(jsx_files, fn path ->
        String.contains?(File.read!(path), ~s(data-testid="step"))
      end)

    assert found,
           "Expected data-testid=\"step\" in at least one JSX/TSX file under #{cwd}/src. " <>
             "Files: #{inspect(jsx_files)}"

    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_git_committed!(cwd)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_commit_subject_length!(cwd)
    Assertions.assert_not_revert_head!(cwd)
    Fixtures.bench_assertions_passed!("static", "iteration_static_react_step_scaffold")
    Fixtures.bench_assertions_passed!("static", "iteration_static_react_step_change")
  end
end

defmodule CodegenTestHarness.Stacks.Static.IterationTest.VueChangeRequest do
  @moduledoc "vue (vite) change-request: new commit with reset button marker"
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

  test "vue change-request lands new commit with reset button marker", %{cwd: cwd} do
    {commits_before, commits_after} =
      Fixtures.change_request(cwd, @vue_first_prompt, @vue_change_prompt,
        stack: "static",
        test_name: "iteration_static_vue_reset"
      )

    assert commits_after > commits_before,
           "vue change request must produce a new commit. Before: #{commits_before}, after: #{commits_after}"

    vue_files =
      [Path.join(cwd, "src/**/*.vue"), Path.join(cwd, "src/**/*.js")]
      |> Enum.flat_map(&Path.wildcard/1)

    found =
      Enum.any?(vue_files, fn path ->
        String.contains?(File.read!(path), ~s(data-testid="reset"))
      end)

    assert found,
           "Expected data-testid=\"reset\" in at least one Vue/JS file under #{cwd}/src. " <>
             "Files: #{inspect(vue_files)}"

    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_git_committed!(cwd)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_commit_subject_length!(cwd)
    Assertions.assert_not_revert_head!(cwd)
    Fixtures.bench_assertions_passed!("static", "iteration_static_vue_reset_scaffold")
    Fixtures.bench_assertions_passed!("static", "iteration_static_vue_reset_change")
  end
end

defmodule CodegenTestHarness.Stacks.Static.IterationTest.MultilingualChangeRequest do
  @moduledoc "multilingual change-request: new commit with language links"
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

  test "multilingual change-request lands new commit with language links", %{cwd: cwd} do
    {commits_before, commits_after} =
      Fixtures.change_request(
        cwd,
        @multilingual_first_prompt,
        @multilingual_change_prompt,
        stack: "static",
        test_name: "iteration_static_multilingual_links"
      )

    assert commits_after > commits_before,
           "multilingual change request must produce a new commit. Before: #{commits_before}, after: #{commits_after}"

    all_files =
      [Path.join(cwd, "**/*.html"), Path.join(cwd, "**/*.md")]
      |> Enum.flat_map(&Path.wildcard/1)

    en_found = Enum.any?(all_files, fn p -> File.read!(p) =~ ~r(href=.?/en) end)
    hr_found = Enum.any?(all_files, fn p -> File.read!(p) =~ ~r(href=.?/hr) end)

    assert en_found,
           "Expected href=\"/en\" link in at least one HTML/MD file under #{cwd}"

    assert hr_found,
           "Expected href=\"/hr\" link in at least one HTML/MD file under #{cwd}"

    Assertions.assert_git_committed!(cwd)
    Assertions.assert_commit_well_formed!(cwd)
    Assertions.assert_commit_subject_length!(cwd)
    Assertions.assert_not_revert_head!(cwd)
    Fixtures.bench_assertions_passed!("static", "iteration_static_multilingual_links_scaffold")
    Fixtures.bench_assertions_passed!("static", "iteration_static_multilingual_links_change")
  end
end
