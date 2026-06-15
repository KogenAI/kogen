/**
 * Tests for context-file-size-gate hook.
 * Mirrors surface-level cases from context-file-size-gate_test.sh.
 * Note: Deep git-state cases (real staged blobs) are covered by the bash twin.
 * Tests here cover behavioral surface accessible without live git state.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeCommitEvent(
  command: string,
  agentType: string,
  toolName = "bash",
) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("context-file-size-gate", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    command: string,
    agentType = "committer",
    toolName = "bash",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../context-file-size-gate");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeCommitEvent(command, agentType, toolName));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("git status (non-commit) passes through", async () => {
    const result = await runHook("git status", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("Read tool with git commit payload passes through (tool guard)", async () => {
    const result = await runHook('git commit -m "x"', "committer", "read");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("echo git commit substring passes through (anchor prevents match)", async () => {
    const result = await runHook('echo "git commit"', "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-git-repo passes through (execSync throws, catch returns)", async () => {
    // In a real non-git dir execSync would throw; our catch block handles it.
    // Here the test process IS in a git repo so we just verify passthrough
    // when there are no staged context/*.md files (empty diff output).
    const result = await runHook('git commit -m "x"', "committer");
    // Either passes through (no staged context files in this repo) or throws
    // internally and passes through via catch. Either way: no block.
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
