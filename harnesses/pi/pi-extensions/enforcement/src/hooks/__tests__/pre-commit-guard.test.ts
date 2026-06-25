/**
 * Tests for pre-commit-guard hook.
 * Mirrors cases from pre-commit-guard_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("pre-commit-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(toolName: string, command: string, agentType = "") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../pre-commit-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent(toolName, command));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("blocks git commit for developer agent", async () => {
    const result = await runHook(
      "bash",
      "git commit -m 'fix'",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git status for developer agent", async () => {
    const result = await runHook(
      "bash",
      "git status",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git commit for committer", async () => {
    const result = await runHook("bash", "git commit -m 'fix'", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks git rebase for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git rebase -i HEAD~2",
      "developer-phoenix-frontend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git push --force for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git push origin main --force",
      "planner-phoenix",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git reset --hard for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git reset --hard HEAD~1",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks for orchestrator (empty agent_type)", async () => {
    const result = await runHook("bash", "git commit -m 'fix'", "");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git add -A for developer agent", async () => {
    const result = await runHook(
      "bash",
      "git add -A",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git add -A for committer", async () => {
    const result = await runHook("bash", "git add -A", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks git stash for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git stash",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git restore foo (no --staged) for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git restore foo",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks git restore --staged foo for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git restore --staged foo",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });
});
