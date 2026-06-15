/**
 * Tests for llm-suite-guard hook.
 * Mirrors cases from llm-suite-guard_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(command: string) {
  return { toolName: "bash", toolCallId: "test-id", input: { command } };
}

describe("llm-suite-guard", () => {
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
    const { register } = await import("../llm-suite-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent(command));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("blocks make llm for developer-*", async () => {
    const result = await runHook("make llm");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks make llm-phoenix for developer-*", async () => {
    const result = await runHook("make llm-phoenix");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows make llm-single FILE=... for developer-*", async () => {
    const result = await runHook(
      "make llm-single FILE=test/my_app/llm_integration/foo_test.exs",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows make llm-phoenix-seed for developer-*", async () => {
    const result = await runHook("make llm-phoenix-seed");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows make llm for committer (non-developer-*)", async () => {
    const result = await runHook("make llm", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows make llm-all for developer-* (suffixed, not bare)", async () => {
    const result = await runHook("make llm-all");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
