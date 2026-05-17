/**
 * Tests for committer-no-trailer-guard hook.
 * Mirrors cases from committer-no-trailer-guard_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("committer-no-trailer-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, agentType = "committer") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../committer-no-trailer-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent("bash", command));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("blocks bare git commit (no -m)", async () => {
    const result = await runHook("git commit");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git commit -m msg", async () => {
    const result = await runHook('git commit -m "Add feature"');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git commit --amend -m msg", async () => {
    const result = await runHook('git commit --amend -m "Fix typo"');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks git commit --file /tmp/msg.txt", async () => {
    const result = await runHook("git commit --file /tmp/msg.txt");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git commit -F /tmp/msg.txt", async () => {
    const result = await runHook("git commit -F /tmp/msg.txt");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("passes through for non-committer agent", async () => {
    const result = await runHook("git commit", "developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git status for committer", async () => {
    const result = await runHook("git status");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git commit -m with single quotes", async () => {
    const result = await runHook("git commit -m 'Add thing'");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
