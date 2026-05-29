defmodule CodegenTestHarness.Stacks.Modes.RefactorTest do
  @moduledoc """
  Asserts {harness}-refactor.sh dispatches correctly and creates or edits a
  Shape Up pitch at <cwd>/codegen/pitches/draft/<slug>.md.

  Note: refactor mode in this repo is a SHAPING mode (not a build mode).
  Both claude-refactor-system-prompt.txt and pi-refactor-system-prompt.txt
  specify "Output: Shape Up pitch at codegen/pitches/draft/<slug>.md".
  The pitch text "refactor → committed refactor" is incorrect; the system
  prompts are the authority.

  Covers cells: claude-refactor, pi-refactor.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 1_800_000

  @slug "test-mode-refactor"
  @prompt_for_claude "Read codegen/pitches/draft/#{@slug}.md and add a '## Solution sketch' section " <>
                       "that names a specific technical approach to solving the problem. Edit the file in place."
  @prompt_for_pi "Read codegen/pitches/draft/#{@slug}.md and add a Solution sketch that names " <>
                   "a specific module to refactor. Edit the pitch file in place. Emit `Ready.` when done."

  setup do
    cwd = Fixtures.isolated_tmp_dir()
    _stub = Fixtures.write_stub_pitch!(cwd, @slug)

    draft_dir = Path.join([cwd, "codegen", "pitches", "draft"])
    before_paths = Path.wildcard(Path.join(draft_dir, "*.md"))

    {:ok, cwd: cwd, before_paths: before_paths}
  end

  test "refactor mode produces or edits a draft pitch with refactor concern",
       %{cwd: cwd, before_paths: before_paths} do
    prompt =
      case Fixtures.harness() do
        "claude" -> @prompt_for_claude
        "pi" -> @prompt_for_pi
      end

    {output, exit_code} = Fixtures.run_mode_launcher(cwd, :refactor, prompt, test_name: "refactor_mode")

    assert exit_code == 0,
           "#{Fixtures.harness()}-refactor exit #{exit_code}:\n#{output}"

    draft_dir = Path.join([cwd, "codegen", "pitches", "draft"])
    after_paths = Path.wildcard(Path.join(draft_dir, "*.md"))

    assert length(after_paths) >= length(before_paths),
           "refactor mode must leave at least the stub pitch in place. " <>
             "Before: #{inspect(before_paths)}. After: #{inspect(after_paths)}"

    # At least one pitch file must contain ## Solution Sketch (section the agent must add;
    # the stub only has ## Problem and ## Appetite, so the assertion is non-trivial)
    found_solution_sketch =
      Enum.any?(after_paths, fn p ->
        body = File.read!(p)
        body =~ ~r/##\s+solution/i
      end)

    assert found_solution_sketch,
           "no draft pitch contains '## solution sketch' (refactor mode must add it). " <>
             "Files: #{inspect(after_paths)}"

    # At least one pitch must reference a technical/refactor concern
    found_refactor_concern =
      Enum.any?(after_paths, fn p ->
        body = File.read!(p)
        body =~ ~r/(module|function|refactor|restructure)/i
      end)

    assert found_refactor_concern,
           "no draft pitch body references a technical refactor concern " <>
             "(module/function/refactor/restructure). Files: #{inspect(after_paths)}"

    Fixtures.bench_assertions_passed!("modes", "refactor_mode")
  end
end
