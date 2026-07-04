defmodule CodegenTestHarness.CallContractTest do
  @moduledoc """
  Hermetic tests for `run_codegen_call/3` harness-name mapping.

  `codegen-call` requires `--harness=claude_code` or `--harness=pi`.
  `Fixtures.harness/0` returns `"claude"` (short form used by `codegen-build`).
  `Fixtures.codegen_call_harness/0` MUST map `"claude"` → `"claude_code"`.

  These tests are fast and deterministic — no LLM, no external process.
  """

  use ExUnit.Case, async: false

  alias CodegenTestHarness.Fixtures

  @codegen_call Path.expand("../../../codegen-call", __DIR__)

  describe "codegen-call --role removed contract" do
    test "usage text does not mention --role" do
      codegen_call = @codegen_call

      {output, exit_code} = System.cmd(codegen_call, [], stderr_to_stdout: true, env: [])

      assert exit_code == 2, "expected exit 2 on missing args, got #{exit_code}"

      refute output =~ ~r/--role/,
             "expected usage to NOT mention --role (it is dead code), got:\n#{output}"
    end

    test "--role=x exits 2 as unknown flag" do
      codegen_call = @codegen_call

      {_output, exit_code} =
        System.cmd(
          codegen_call,
          [
            "--harness=claude_code",
            "--role=x",
            "--model=haiku",
            "--effort=low",
            "--system-prompt",
            "@/nonexistent",
            "prompt"
          ],
          stderr_to_stdout: true,
          env: []
        )

      assert exit_code == 2, "expected exit 2 for unknown flag --role, got #{exit_code}"
    end
  end

  describe "codegen_call_harness/0" do
    test "maps \"claude\" to \"claude_code\" when HARNESS env is unset" do
      # Ensure HARNESS env is unset (default path)
      original = System.get_env("HARNESS")

      try do
        System.delete_env("HARNESS")
        assert Fixtures.codegen_call_harness() == "claude_code"
      after
        if original, do: System.put_env("HARNESS", original)
      end
    end

    test "maps \"claude\" to \"claude_code\" when HARNESS=claude" do
      original = System.get_env("HARNESS")

      try do
        System.put_env("HARNESS", "claude")
        assert Fixtures.codegen_call_harness() == "claude_code"
      after
        case original do
          nil -> System.delete_env("HARNESS")
          v -> System.put_env("HARNESS", v)
        end
      end
    end

    test "passes \"pi\" through unchanged when HARNESS=pi" do
      original = System.get_env("HARNESS")

      try do
        System.put_env("HARNESS", "pi")
        assert Fixtures.codegen_call_harness() == "pi"
      after
        case original do
          nil -> System.delete_env("HARNESS")
          v -> System.put_env("HARNESS", v)
        end
      end
    end
  end
end
