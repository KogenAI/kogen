/**
 * Tests for dev-no-ci hook.
 * Mirrors cases from dev-no-ci_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("dev-no-ci", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    command: string,
    agentType = "developer-phoenix-backend",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../dev-no-ci");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent("bash", command));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("blocks make ci for developer", async () => {
    const result = await runHook("make ci");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks make ci-fast for developer", async () => {
    const result = await runHook("make ci-fast");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks bare mix test for developer", async () => {
    const result = await runHook("mix test");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks mix test --flags-only for developer", async () => {
    const result = await runHook("mix test --trace");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows mix test with specific file path", async () => {
    const result = await runHook(
      "mix test test/combobulate/llm/backend/pi_test.exs",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through for non-developer agent", async () => {
    const result = await runHook("make ci", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks make llm-phoenix for developer", async () => {
    const result = await runHook("make llm-phoenix");
    assert.ok((result as { block?: boolean }).block === true);
  });
});
