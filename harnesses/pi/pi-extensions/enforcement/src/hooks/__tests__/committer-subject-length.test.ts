/**
 * Tests for committer-subject-length hook.
 * Mirrors cases from committer-subject-length_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(command: string) {
  return { toolName: "bash", toolCallId: "test-id", input: { command } };
}

describe("committer-subject-length", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, agentType = "committer") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../committer-subject-length");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent(command));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("blocks commit with subject > 50 bytes", async () => {
    const longSubject = "A".repeat(51);
    const result = await runHook(`git commit -m "${longSubject}"`);
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows commit with subject exactly 50 bytes", async () => {
    const subject = "A".repeat(50);
    const result = await runHook(`git commit -m "${subject}"`);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows commit with short subject", async () => {
    const result = await runHook('git commit -m "Fix bug"');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through for non-committer agent", async () => {
    const longSubject = "A".repeat(60);
    const result = await runHook(
      `git commit -m "${longSubject}"`,
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through for non-commit commands", async () => {
    const result = await runHook("git status");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows codegen-log write narrating a long subject", async () => {
    const longSubject = "A".repeat(51);
    const result = await runHook(
      `codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git commit -m "${longSubject}" — denied as expected (subject too long).\nEOF`,
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("still blocks real subject > 50 bytes unchanged", async () => {
    const longSubject = "A".repeat(51);
    const result = await runHook(`git commit -m "${longSubject}"`);
    assert.ok((result as { block?: boolean }).block === true);
  });
});
