defmodule Kogen.ClaudeCodeInstallerTest do
  use ExUnit.Case, async: true

  # Subprocesses run from this checkout, never the shared VM's mutable cwd.
  @project_root Path.expand("../..", __DIR__)

  test "the managed-runtime installer passes its synthetic archive suite" do
    script = Path.expand("../support/claude_code_installer_test.py", __DIR__)

    assert {_output, 0} =
             System.cmd("python3", [script], stderr_to_stdout: true, cd: @project_root)
  end
end
