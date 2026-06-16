defmodule CodegenTestHarness.Stacks.Modes.BuildTest do
  @moduledoc """
  Deterministic contract test for the build launchers' launch-cwd
  normalisation. Stubs the underlying `codegen-build` binary (BUILD_BIN) so no
  LLM call is made. Verifies that launching `{harness}-build.sh` from inside
  `codegen/pitches/` normalises cwd back to the repo root before exec, so the
  basename resolver keys off the correct `codegen/pitches/ready/` dir and emits
  the relative pitch mention rather than the literal-token fallthrough.

  Covers cells: claude-build, pi-build.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Fixtures

  @codegen_dir Path.expand("../../../../", __DIR__)

  @slug "test-mode-build"

  @tag timeout: 30_000
  test "build launcher launched from nested codegen/pitches/ cwd recovers to repo root" do
    cwd = Fixtures.isolated_tmp_dir()

    # The build resolver keys off codegen/pitches/ready/ (not draft/). Write the
    # stub pitch THERE so a successful cwd-normalisation produces the relative
    # @-mention; a failed normalisation would mis-resolve and fall through to the
    # literal-token branch.
    ready_dir = Path.join([cwd, "codegen", "pitches", "ready"])
    File.mkdir_p!(ready_dir)
    ready_pitch_path = Path.join(ready_dir, "#{@slug}.md")
    File.write!(ready_pitch_path, "# Pitch: #{@slug}\n\n## Problem\n\nStub.\n")

    # Nested cwd — what a user inside codegen/pitches/ would have.
    nested_cwd = Path.join([cwd, "codegen", "pitches"])
    File.mkdir_p!(nested_cwd)

    harness_val = Fixtures.harness()
    script = Path.join([@codegen_dir, "harnesses", harness_val, "#{harness_val}-build.sh"])
    assert File.exists?(script), "launcher not found: #{script}"

    # Stub the underlying BUILD_BIN (codegen-build) so no real build runs.
    # The stub appends every received arg to a capture file then exits 0.
    # BUILD_BIN resolves to "$OCG_CODEGEN_DIR/codegen-build" (launcher line 6/11),
    # so the stub MUST be named codegen-build and OCG_CODEGEN_DIR MUST point at
    # stub_dir (NOT the real repo, or the launcher would exec the real binary).
    stub_dir = Path.join(cwd, "stub_bin")
    File.mkdir_p!(stub_dir)

    capture_file = Path.join(cwd, "args.txt")
    stub_bin = Path.join(stub_dir, "codegen-build")

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
      {"OCG_CODEGEN_DIR", stub_dir}
    ]

    # Launch from nested cwd with the pitch slug as the sole arg. The launcher
    # must cd back to repo root, resolve the slug against codegen/pitches/ready/,
    # and exec the stub with the relative mention.
    {output, exit_code} =
      System.cmd("bash", [script, @slug], cd: nested_cwd, env: env, stderr_to_stdout: true)

    assert exit_code == 0,
           "#{harness_val}-build exited #{exit_code} when launched from nested cwd:\n#{output}"

    captured =
      if File.exists?(capture_file), do: File.read!(capture_file), else: ""

    # claude emits @codegen/pitches/ready/<slug>.md; pi emits the same without @.
    expected_mention =
      case harness_val do
        "claude" -> "@codegen/pitches/ready/#{@slug}.md"
        _ -> "codegen/pitches/ready/#{@slug}.md"
      end

    # Load-bearing assertion: the resolved relative mention proves the basename
    # resolver keyed off the correct READY_DIR (repo-root-relative), i.e. the
    # launcher cd-ed before resolving. If cwd normalisation failed, READY_DIR
    # would resolve under codegen/pitches/, the slug would NOT match, and the
    # arg would fall through to the literal token "#{@slug}".
    assert String.contains?(captured, expected_mention),
           "captured args must contain relative mention #{inspect(expected_mention)} " <>
             "(proving cwd was normalised before basename resolution). " <>
             "Captured:\n#{captured}\nLauncher output:\n#{output}"

    refute String.contains?(captured, "\n#{@slug}\n") or captured == "#{@slug}\n",
           "slug must NOT appear as a bare literal token (would mean resolver " <>
             "mis-resolved READY_DIR). Captured:\n#{captured}"
  end
end
