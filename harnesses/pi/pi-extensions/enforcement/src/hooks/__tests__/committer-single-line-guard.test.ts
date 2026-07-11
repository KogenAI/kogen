/**
 * Tests for committer-single-line-guard hook.
 * Mirrors cases from committer-single-line-guard_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("committer-single-line-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, agentType = "committer") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../committer-single-line-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent("bash", command));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("allows single-line -m", async () => {
    const result = await runHook('git commit -m "Add feature"');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks -m with literal backslash-n", async () => {
    const result = await runHook('git commit -m "Add feature\\ndetails"');
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows bare git commit (no -m, pass-through)", async () => {
    const result = await runHook("git commit");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git commit-tree (word-boundary fix: no substring match on git commit)", async () => {
    const result = await runHook("git commit-tree abc123 -p def456");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows non-committer with multi-line message", async () => {
    const result = await runHook(
      'git commit -m "bad\\nmsg"',
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks -m with actual embedded newline", async () => {
    const result = await runHook('git commit -m "Add feature\ndetails"');
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows non-bash tool", async () => {
    const event = {
      toolName: "read",
      toolCallId: "test-id",
      input: { file_path: "/tmp/foo" },
    };
    process.env["AGENT_TYPE"] = "committer";
    const { register } = await import("../committer-single-line-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    const result = await _capturedHandler(event);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows --amend -m single-line", async () => {
    const result = await runHook('git commit --amend -m "Fix typo"');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git status", async () => {
    const result = await runHook("git status");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows codegen-log write narrating literal-backslash-n commit", async () => {
    const result = await runHook(
      'codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git commit -m "Add feature\\ndetails" — denied as expected.\nEOF',
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("still blocks real -m with literal backslash-n unchanged", async () => {
    const result = await runHook('git commit -m "Add feature\\ndetails"');
    assert.ok((result as { block?: boolean }).block === true);
  });
});
