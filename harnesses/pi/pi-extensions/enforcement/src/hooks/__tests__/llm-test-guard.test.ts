/**
 * Tests for llm-test-guard hook.
 * Mirrors cases from llm-test-guard_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("llm-test-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, toolName = "bash") {
    const { register } = await import("../llm-test-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent(toolName, command));
  }

  it("blocks bare mix test --only llm_integration", async () => {
    const result = await runHook("mix test --only llm_integration");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks mix test --only llm_integration with only PARTITION=1 set", async () => {
    const result = await runHook(
      "MIX_TEST_PARTITION=1 mix test --only llm_integration test/foo_test.exs",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks mix test --only llm_integration PARTITION=3 PARTITIONS=10", async () => {
    const result = await runHook(
      "MIX_TEST_PARTITION=3 MIX_TEST_PARTITIONS=10 mix test --only llm_integration test/foo_test.exs",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows PARTITION=1 PARTITIONS=1 with .exs path", async () => {
    const result = await runHook(
      "MIX_TEST_PARTITION=1 MIX_TEST_PARTITIONS=1 mix test --only llm_integration test/combobulate/llm_integration/foo_test.exs",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows make llm-single (no mix test literal)", async () => {
    const result = await runHook("make llm-single FILE=test/foo_test.exs");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows make llm (no mix test literal)", async () => {
    const result = await runHook("make llm");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows non-bash tool", async () => {
    const result = await runHook("mix test --only llm_integration", "read");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks PARTITION=1 PARTITIONS=1 without .exs path", async () => {
    const result = await runHook(
      "MIX_TEST_PARTITION=1 MIX_TEST_PARTITIONS=1 mix test --only llm_integration",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });
});
