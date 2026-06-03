defmodule CodegenTestHarness.Stacks.Modes.OpsTest do
  @moduledoc """
  Deterministic tests for `claude-ops.sh` `save_ssh_alias` Host-block write.

  No real SSH connections or LLM calls. Stubs `claude` on PATH so the trailing
  `exec claude` in claude-ops.sh is harmless. Overrides HOME to a temp dir so
  the real `~/.ssh/config` is never touched.

  Exercises lines 34-65 (save_ssh_alias) and the "miss → user types IP → save"
  path (lines 70-93).
  """

  use ExUnit.Case, async: false

  @moduletag :ops

  @codegen_dir Path.expand("../../../../", __DIR__)
  @ops_script Path.join([@codegen_dir, "harnesses", "claude", "claude-ops.sh"])

  setup do
    # Use a temp dir as HOME so ~/.ssh/config is isolated
    tmp = Path.join(System.tmp_dir!(), "ops_test_#{:os.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, ".ssh"))
    File.write!(Path.join(tmp, ".ssh/config"), "# placeholder\n")

    # Create a stub claude binary that exits 0
    stub_dir = Path.join(tmp, "stub_bin")
    File.mkdir_p!(stub_dir)
    stub_claude = Path.join(stub_dir, "claude")
    File.write!(stub_claude, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(stub_claude, 0o755)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, stub_dir: stub_dir}
  end

  @tag timeout: 30_000
  test "save_ssh_alias writes Host block to ~/.ssh/config", %{tmp: tmp, stub_dir: stub_dir} do
    ssh_config = Path.join(tmp, ".ssh/config")

    # Provide a raw IP as the "alias or IP" when prompted (stdin input)
    # This exercises the "miss → user types IP" path in claude-ops.sh L70-93.
    # The IP == server_resolved → triggers save_ssh_alias.
    hostname_input = "192.168.99.42\n"

    original_path = System.get_env("PATH", "/usr/bin:/bin")

    env = [
      {"HOME", tmp},
      {"PATH", stub_dir <> ":" <> original_path},
      {"OCG_CODEGEN_DIR", @codegen_dir}
    ]

    # We need a git repo for `git rev-parse --show-toplevel`.
    # Use @codegen_dir which is already a git repo.
    cmd = "echo #{String.trim(hostname_input)} | bash #{@ops_script} staging 2>&1"

    {output, exit_code} =
      System.cmd(
        "bash",
        ["-c", cmd],
        cd: @codegen_dir,
        env: env
      )

    # Exit 0 from stub claude means success
    assert exit_code == 0,
           "claude-ops.sh exited #{exit_code}. Output:\n#{output}"

    config_content = File.read!(ssh_config)

    assert String.contains?(config_content, "# ops-generated:"),
           "expected '# ops-generated:' comment in #{ssh_config}.\nContent:\n#{config_content}"

    # project_name = basename of git toplevel (codegen)
    project_name = Path.basename(@codegen_dir)
    candidate = "#{project_name}-staging"

    assert String.contains?(config_content, "Host #{candidate}"),
           "expected 'Host #{candidate}' in #{ssh_config}.\nContent:\n#{config_content}"

    assert String.contains?(config_content, "HostName"),
           "expected 'HostName' line in #{ssh_config}.\nContent:\n#{config_content}"
  end
end
