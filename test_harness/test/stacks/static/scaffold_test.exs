defmodule CodegenTestHarness.Stacks.Static.ScaffoldTest do
  @moduledoc """
  Asserts that `codegen-build --stack=static` provisions each supported static
  substack from an empty directory: hugo, vite-react, vite-vue, multilingual.

  Each test:
  1. Runs `codegen-build` with `--stack=static` and a substack-specific prompt.
  2. Asserts exit 0.
  3. Asserts stack-specific files exist.
  4. Runs the appropriate build assertion.
  5. Asserts at least one git commit landed.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 1_800_000

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  # ── hugo ──────────────────────────────────────────────────────────────────────

  test "codegen-build provisions hugo blog from empty dir", %{cwd: cwd} do
    harness = Fixtures.harness()

    {output, exit_code} =
      System.cmd(
        Fixtures.codegen_build_path(),
        [
          "--harness=#{harness}",
          "--stack=static",
          "--non-interactive",
          "--cwd=#{cwd}",
          "Create a Hugo blog with three sample posts about gardening. Each post must have a title and at least 50 words of body content."
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "codegen-build failed (harness=#{harness}, exit=#{exit_code}):\n#{output}"

    md_files = Path.wildcard(Path.join(cwd, "content/**/*.md"))
    assert md_files != [], "no content/**/*.md files found under #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_hugo_builds!(cwd)
    Assertions.assert_git_committed!(cwd)
  end

  # ── vite-react ────────────────────────────────────────────────────────────────

  test "codegen-build provisions vite-react app from empty dir", %{cwd: cwd} do
    harness = Fixtures.harness()

    {output, exit_code} =
      System.cmd(
        Fixtures.codegen_build_path(),
        [
          "--harness=#{harness}",
          "--stack=static",
          "--non-interactive",
          "--cwd=#{cwd}",
          ~s(Create a React app with Vite that shows a counter with data-testid="increment" and data-testid="count" elements.)
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "codegen-build failed (harness=#{harness}, exit=#{exit_code}):\n#{output}"

    jsx_files =
      [Path.join(cwd, "src/**/*.jsx"), Path.join(cwd, "src/**/*.tsx")]
      |> Enum.flat_map(&Path.wildcard/1)

    assert jsx_files != [],
           "no src/**/*.{jsx,tsx} files found under #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_git_committed!(cwd)
  end

  # ── vite-vue ──────────────────────────────────────────────────────────────────

  test "codegen-build provisions vite-vue app from empty dir", %{cwd: cwd} do
    harness = Fixtures.harness()

    {output, exit_code} =
      System.cmd(
        Fixtures.codegen_build_path(),
        [
          "--harness=#{harness}",
          "--stack=static",
          "--non-interactive",
          "--cwd=#{cwd}",
          ~s(Create a Vue app with Vite that displays a color picker with a hex output display element with data-testid="hex-output".)
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "codegen-build failed (harness=#{harness}, exit=#{exit_code}):\n#{output}"

    vue_files = Path.wildcard(Path.join(cwd, "src/**/*.vue"))

    assert vue_files != [],
           "no src/**/*.vue files found under #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_git_committed!(cwd)
  end

  # ── multilingual ──────────────────────────────────────────────────────────────

  test "codegen-build provisions multilingual site from empty dir", %{cwd: cwd} do
    harness = Fixtures.harness()

    {output, exit_code} =
      System.cmd(
        Fixtures.codegen_build_path(),
        [
          "--harness=#{harness}",
          "--stack=static",
          "--non-interactive",
          "--cwd=#{cwd}",
          "Create a simple multilingual site with both English and Croatian versions. Include a nav with language switcher links."
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "codegen-build failed (harness=#{harness}, exit=#{exit_code}):\n#{output}"

    site_files =
      [Path.join(cwd, "**/*.html"), Path.join(cwd, "**/*.md")]
      |> Enum.flat_map(&Path.wildcard/1)

    assert site_files != [],
           "no **/*.{html,md} files found under #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_git_committed!(cwd)
  end
end
