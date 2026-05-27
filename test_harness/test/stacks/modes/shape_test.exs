defmodule CodegenTestHarness.Stacks.Modes.ShapeTest do
  @moduledoc """
  Asserts {harness}-shape.sh dispatches correctly and edits or creates a
  Shape Up pitch at <cwd>/codegen/pitches/draft/<slug>.md.

  Covers cells: claude-shape, pi-shape.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 1_800_000

  @slug "test-mode-shape"
  @prompt_for_claude "Read codegen/pitches/draft/#{@slug}.md and add a '## Solution sketch' section " <>
                       "describing one concrete approach to solving the problem. Edit the file in place."
  @prompt_for_pi "Read codegen/pitches/draft/#{@slug}.md and add a '## Solution sketch' section describing one concrete approach. " <>
                   "Edit the pitch file in place. Emit `Ready.` when done."

  setup do
    cwd = Fixtures.isolated_tmp_dir()
    _stub = Fixtures.write_stub_pitch!(cwd, @slug)

    draft_dir = Path.join([cwd, "codegen", "pitches", "draft"])
    before_paths = Path.wildcard(Path.join(draft_dir, "*.md"))

    {:ok, cwd: cwd, before_paths: before_paths}
  end

  test "shape mode produces or edits a draft pitch",
       %{cwd: cwd, before_paths: before_paths} do
    prompt =
      case Fixtures.harness() do
        "claude" -> @prompt_for_claude
        "pi" -> @prompt_for_pi
      end

    {output, exit_code} = Fixtures.run_mode_launcher(cwd, :shape, prompt)

    assert exit_code == 0,
           "#{Fixtures.harness()}-shape exit #{exit_code}:\n#{output}"

    # Either a new pitch appeared OR the stub was edited (mtime increased)
    draft_dir = Path.join([cwd, "codegen", "pitches", "draft"])
    after_paths = Path.wildcard(Path.join(draft_dir, "*.md"))

    assert length(after_paths) >= length(before_paths),
           "shape mode must leave at least the stub pitch in place. " <>
             "Before: #{inspect(before_paths)}. After: #{inspect(after_paths)}"

    # At least one pitch file must contain ## Solution Sketch (section the agent must add;
    # the stub only has ## Problem and ## Appetite, so the assertion is non-trivial)
    found_solution_sketch =
      Enum.any?(after_paths, fn p ->
        body = File.read!(p)
        body =~ ~r/##\s+solution/i
      end)

    assert found_solution_sketch,
           "no draft pitch contains '## solution sketch' (shape mode must add it). " <>
             "Files: #{inspect(after_paths)}"

  end
end
