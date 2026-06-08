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
