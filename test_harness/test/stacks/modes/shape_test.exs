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

  @codegen_dir Path.expand("../../../../", __DIR__)

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

    {output, exit_code} = Fixtures.run_mode_launcher(cwd, :shape, prompt, test_name: "shape_mode")

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

    Fixtures.bench_assertions_passed!("modes", "shape_mode")
  end

  # Deterministic test — stubs the underlying launcher binary so no LLM call is
  # made. Verifies that launching from inside codegen/pitches/ normalises cwd
  # back to the repo root and the stub pitch is still reachable.
  @tag timeout: 30_000
  test "shape launcher launched from nested codegen/pitches/ cwd recovers to repo root" do
    cwd = Fixtures.isolated_tmp_dir()
    _stub = Fixtures.write_stub_pitch!(cwd, @slug)

    # Draft path from the perspective of the (non-nested) repo root
    draft_dir = Path.join([cwd, "codegen", "pitches", "draft"])
    stub_pitch_path = Path.join(draft_dir, "#{@slug}.md")
    assert File.exists?(stub_pitch_path), "stub pitch must exist before test: #{stub_pitch_path}"

    # Nested cwd — this is what a user inside codegen/pitches/ would have
    nested_cwd = Path.join([cwd, "codegen", "pitches"])
    File.mkdir_p!(nested_cwd)

    harness_val = Fixtures.harness()
    script = Path.join([@codegen_dir, "harnesses", harness_val, "#{harness_val}-shape.sh"])
    assert File.exists?(script), "launcher not found: #{script}"

    # Stub the underlying binary so no real LLM call is made.
    # The stub writes all its received args to a file then exits 0.
    stub_dir = Path.join(cwd, "stub_bin")
    File.mkdir_p!(stub_dir)

    {binary_name, env_key} =
      case harness_val do
        "claude" -> {"claude", "CLAUDE_NONINTERACTIVE"}
        _ -> {"pi", "PI_NON_INTERACTIVE"}
      end

    capture_file = Path.join(cwd, "args.txt")

    stub_bin = Path.join(stub_dir, binary_name)

    File.write!(stub_bin, """
    #!/usr/bin/env bash
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "#{capture_file}"
    done
    exit 0
    """)

    File.chmod!(stub_bin, 0o755)

    original_path = System.get_env("PATH", "/usr/bin:/bin")

    env = [
      {"HOME", cwd},
      {"PATH", stub_dir <> ":" <> original_path},
      {"OCG_CODEGEN_DIR", @codegen_dir},
      {env_key, "1"}
    ]

    # Launch from nested cwd — launcher must cd back to cwd (repo root)
    {output, exit_code} =
      System.cmd("bash", [script], cd: nested_cwd, env: env, stderr_to_stdout: true)

    assert exit_code == 0,
           "#{harness_val}-shape exited #{exit_code} when launched from nested cwd:\n#{output}"

    # Stub pitch must still be readable from the recovered root — this is the
    # load-bearing assertion: if cwd normalisation failed the draft_dir would
    # resolve relative to codegen/pitches/ and the file would not be found.
    assert File.exists?(stub_pitch_path),
           "stub pitch must still be present after launcher run: #{stub_pitch_path}. " <>
             "output:\n#{output}"
  end
end
