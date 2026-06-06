defmodule CodegenTestHarness.Stacks.Modes.HeadlessLauncherTest do
  @moduledoc """
  Deterministic tests for CLAUDE_NONINTERACTIVE=1 headless mode across the four
  investigative launchers: claude-shape, claude-refactor, claude-ops, claude-debug.

  No real SSH connections or LLM calls. Stubs `claude` on PATH with a script that
  captures all arguments to a file. Overrides HOME to a temp dir. Uses an explicit
  env list with PATH — never env: [] — so bash scripts can resolve the shebang.
  """

  use ExUnit.Case, async: false

  @moduletag :headless

  @codegen_dir Path.expand("../../../../", __DIR__)

  @shape_script Path.join([@codegen_dir, "harnesses", "claude", "claude-shape.sh"])
  @refactor_script Path.join([@codegen_dir, "harnesses", "claude", "claude-refactor.sh"])
  @ops_script Path.join([@codegen_dir, "harnesses", "claude", "claude-ops.sh"])
  @debug_script Path.join([@codegen_dir, "harnesses", "claude", "claude-debug.sh"])

  # Expected headless flags (subset check — all must appear in captured args)
  @headless_flags ~w(--print --no-session-persistence --disable-slash-commands)

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "headless_test_#{:os.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, ".ssh"))
    File.write!(Path.join(tmp, ".ssh/config"), "# placeholder\n")

    stub_dir = Path.join(tmp, "stub_bin")
    File.mkdir_p!(stub_dir)

    capture_file = Path.join(tmp, "claude_args.txt")

    # Stub claude: appends all arguments (one per line) to capture file, exits 0
    stub_claude = Path.join(stub_dir, "claude")

    File.write!(stub_claude, """
    #!/usr/bin/env bash
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "#{capture_file}"
    done
    exit 0
    """)

    File.chmod!(stub_claude, 0o755)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, stub_dir: stub_dir, capture_file: capture_file}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp base_env(tmp, stub_dir) do
    original_path = System.get_env("PATH", "/usr/bin:/bin")

    [
      {"HOME", tmp},
      {"PATH", stub_dir <> ":" <> original_path},
      {"OCG_CODEGEN_DIR", @codegen_dir}
    ]
  end

  defp run_launcher(script, args, env) do
    cmd = Enum.join(["bash", script | args], " ")

    System.cmd(
      "bash",
      ["-c", cmd <> " 2>&1"],
      cd: @codegen_dir,
      env: env
    )
  end

  defp captured_flags(capture_file) do
    case File.read(capture_file) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _} -> []
    end
  end

  defp assert_headless_flags(flags) do
    for flag <- @headless_flags do
      assert flag in flags,
             "Expected #{flag} in captured flags.\nGot: #{inspect(flags)}"
    end

    # --output-format stream-json must appear as consecutive args
    pairs = Enum.zip(flags, tl(flags))

    assert {"--output-format", "stream-json"} in pairs,
           "Expected --output-format stream-json in captured flags.\nGot: #{inspect(flags)}"
  end

  defp refute_headless_flags(flags) do
    refute "--print" in flags,
           "Expected --print to be absent in non-headless mode.\nGot: #{inspect(flags)}"
  end

  # ── claude-shape.sh ──────────────────────────────────────────────────────────

  @tag timeout: 30_000
  test "claude-shape WITH CLAUDE_NONINTERACTIVE=1 passes all headless flags", %{
    tmp: tmp,
    stub_dir: stub_dir,
    capture_file: capture_file
  } do
    env = base_env(tmp, stub_dir) ++ [{"CLAUDE_NONINTERACTIVE", "1"}]

    # cold-start (no args) path
    {_output, exit_code} = run_launcher(@shape_script, [], env)
    assert exit_code == 0

    flags = captured_flags(capture_file)
    assert_headless_flags(flags)
  end

  @tag timeout: 30_000
  test "claude-shape WITHOUT CLAUDE_NONINTERACTIVE does not pass --print", %{
    tmp: tmp,
    stub_dir: stub_dir,
    capture_file: capture_file
  } do
    env = base_env(tmp, stub_dir)

    {_output, exit_code} = run_launcher(@shape_script, [], env)
    assert exit_code == 0

    flags = captured_flags(capture_file)
    refute_headless_flags(flags)
  end

  # ── claude-refactor.sh ───────────────────────────────────────────────────────

  @tag timeout: 30_000
  test "claude-refactor WITH CLAUDE_NONINTERACTIVE=1 passes all headless flags", %{
    tmp: tmp,
    stub_dir: stub_dir,
    capture_file: capture_file
  } do
    env = base_env(tmp, stub_dir) ++ [{"CLAUDE_NONINTERACTIVE", "1"}]

    {_output, exit_code} = run_launcher(@refactor_script, [], env)
    assert exit_code == 0

    flags = captured_flags(capture_file)
    assert_headless_flags(flags)
  end

  @tag timeout: 30_000
  test "claude-refactor WITHOUT CLAUDE_NONINTERACTIVE does not pass --print", %{
    tmp: tmp,
    stub_dir: stub_dir,
    capture_file: capture_file
  } do
    env = base_env(tmp, stub_dir)

    {_output, exit_code} = run_launcher(@refactor_script, [], env)
    assert exit_code == 0

    flags = captured_flags(capture_file)
    refute_headless_flags(flags)
  end

  # ── claude-ops.sh ────────────────────────────────────────────────────────────

  @tag timeout: 30_000
  test "claude-ops WITH CLAUDE_NONINTERACTIVE=1 + missing ssh alias exits non-zero (no hang)", %{
    tmp: tmp,
    stub_dir: stub_dir
  } do
    # No ssh alias for "myserver" in the isolated ~/.ssh/config
    env = base_env(tmp, stub_dir) ++ [{"CLAUDE_NONINTERACTIVE", "1"}]

    {output, exit_code} = run_launcher(@ops_script, ["myserver"], env)
    assert exit_code != 0, "Expected non-zero exit when ssh alias missing. Output:\n#{output}"
    assert String.contains?(output, "not found"), "Expected 'not found' in output.\nGot: #{output}"
  end

  @tag timeout: 30_000
  test "claude-ops WITH CLAUDE_NONINTERACTIVE=1 + known alias passes all headless flags", %{
    tmp: tmp,
    stub_dir: stub_dir,
    capture_file: capture_file
  } do
    # Pre-seed a Host block for the candidate alias
    project_name = Path.basename(@codegen_dir)
    alias_name = "#{project_name}-staging"

    ssh_config_path = Path.join(tmp, ".ssh/config")

    File.write!(ssh_config_path, """
    # placeholder
    Host #{alias_name}
        HostName 10.0.0.1
    """)

    env = base_env(tmp, stub_dir) ++ [{"CLAUDE_NONINTERACTIVE", "1"}]

    {_output, exit_code} = run_launcher(@ops_script, ["staging"], env)
    assert exit_code == 0

    flags = captured_flags(capture_file)
    assert_headless_flags(flags)
  end

  # ── claude-debug.sh ──────────────────────────────────────────────────────────

  @tag timeout: 30_000
  test "claude-debug WITH CLAUDE_NONINTERACTIVE=1 + missing ssh alias exits non-zero (no hang)", %{
    tmp: tmp,
    stub_dir: stub_dir
  } do
    env = base_env(tmp, stub_dir) ++ [{"CLAUDE_NONINTERACTIVE", "1"}]

    {output, exit_code} = run_launcher(@debug_script, ["myserver"], env)
    assert exit_code != 0, "Expected non-zero exit when ssh alias missing. Output:\n#{output}"
    assert String.contains?(output, "not found"), "Expected 'not found' in output.\nGot: #{output}"
  end

  @tag timeout: 30_000
  test "claude-debug WITH CLAUDE_NONINTERACTIVE=1 + known alias passes all headless flags", %{
    tmp: tmp,
    stub_dir: stub_dir,
    capture_file: capture_file
  } do
    project_name = Path.basename(@codegen_dir)
    alias_name = "#{project_name}-production"

    ssh_config_path = Path.join(tmp, ".ssh/config")

    File.write!(ssh_config_path, """
    # placeholder
    Host #{alias_name}
        HostName 10.0.0.2
    """)

    env = base_env(tmp, stub_dir) ++ [{"CLAUDE_NONINTERACTIVE", "1"}]

    {_output, exit_code} = run_launcher(@debug_script, ["production"], env)
    assert exit_code == 0

    flags = captured_flags(capture_file)
    assert_headless_flags(flags)
  end
end
