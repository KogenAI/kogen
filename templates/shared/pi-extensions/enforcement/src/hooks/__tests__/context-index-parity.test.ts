/**
 * Tests for context-index-parity hook.
 * Mirrors cases from context-index-parity_test.sh.
 * Note: This hook runs git diff --cached requiring a real git repo.
 * Tests cover the behavioral surface accessible without git state.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeCommitEvent(command: string, agentType: string, toolName = "bash") {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("context-index-parity", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, agentType = "committer", toolName = "bash") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../context-index-parity");
    register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
    return _capturedHandler(makeCommitEvent(command, agentType, toolName));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("git status (non-commit) passes through", async () => {
    const result = await runHook("git status", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("Read tool with git commit payload passes through", async () => {
    const result = await runHook('git commit -m "x"', "committer", "read");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-committer passes through regardless of command", async () => {
    const result = await runHook('git commit -m "x"', "developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("echo git commit substring passes through (anchor prevents match)", async () => {
    const result = await runHook('echo "git commit"', "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
