defmodule CodegenTestHarness.Stacks.Static.HtmlScaffoldTest do
  @moduledoc """
  Asserts that `codegen-build --stack=static` produces a static HTML page
  containing the requested content, for both `HARNESS=claude` and
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

  test "codegen-build provisions static html site from empty dir", %{cwd: cwd} do
    harness = Fixtures.harness()

    {output, exit_code} =
      System.cmd(
        Fixtures.codegen_build_path(),
        [
          "--harness=#{harness}",
          "--stack=static",
          "--non-interactive",
          "--cwd=#{cwd}",
          "make a single static html page with a hello world heading"
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "codegen-build failed (harness=#{harness}, exit=#{exit_code}):\n#{output}"

    html_files = Path.wildcard(Path.join(cwd, "**/*.html"))
    assert html_files != [], "no .html files found under #{cwd}\n--- output ---\n#{output}"

    matching =
      Enum.find(html_files, fn path ->
        File.read!(path) =~ ~r/hello\s*world/i
      end)

    assert matching,
           "no .html file under #{cwd} contains /hello\\s*world/i\nfiles: #{inspect(html_files)}"

    Assertions.assert_git_committed!(cwd)
  end
end
