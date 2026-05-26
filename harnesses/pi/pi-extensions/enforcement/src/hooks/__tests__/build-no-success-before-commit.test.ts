/**
 * Tests for build-no-success-before-commit hook.
 * Mirrors cases from build-no-success-before-commit_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeBashEvent(command: string) {
  return { toolName: "bash", toolCallId: "test-id", input: { command } };
}

describe("build-no-success-before-commit", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, toolName = "bash") {
    const { register } = await import("../build-no-success-before-commit");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName,
      toolCallId: "test-id",
      input: { command },
    });
  }

  beforeEach(() => {
    delete process.env["COMBOBULATE_BUILD_START_TS"];
    delete process.env["AGENT_TYPE"];
  });

  it("passes through when no BUILD_RESULT: in command", async () => {
    const result = await runHook("echo hello");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through when COMBOBULATE_BUILD_START_TS unset", async () => {
    const result = await runHook('echo "BUILD_RESULT: success"');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through for non-bash tool with BUILD_RESULT:", async () => {
    process.env["COMBOBULATE_BUILD_START_TS"] = String(
      Math.floor(Date.now() / 1000),
    );
    const result = await runHook("BUILD_RESULT: foo", "read");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
