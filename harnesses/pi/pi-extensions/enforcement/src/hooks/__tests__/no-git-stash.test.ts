/**
 * Tests for no-git-stash hook.
 * Mirrors cases from no-git-stash_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

// Inline minimal test harness — simulates pi.on("tool_call") dispatch
function makeToolCallEvent(toolName: string, command: string) {
  return {
    toolName,
    toolCallId: "test-id",
    input: { command },
  };
}

describe("no-git-stash", () => {
  let blockResult: unknown;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  async function runHook(toolName: string, command: string) {
    const { register } = await import("../no-git-stash");
    blockResult = undefined;
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    blockResult = await _capturedHandler(makeToolCallEvent(toolName, command));
    return blockResult;
  }

  it("blocks git stash", async () => {
    const result = await runHook("bash", "git stash");
    assert.deepStrictEqual(result, {
      block: true,
      reason:
        "git stash forbidden. Commit WIP to a scratch branch or use worktrees. Stash hides work from orchestrator + reviewer.",
    });
  });

  it("blocks git stash push", async () => {
    const result = await runHook("bash", "git stash push -m wip");
    assert.ok((result as { block: boolean }).block === true);
  });

  it("blocks git stash pop", async () => {
    const result = await runHook("bash", "git stash pop");
    assert.ok((result as { block: boolean }).block === true);
  });

  it("blocks git stash list", async () => {
    const result = await runHook("bash", "git stash list");
    assert.ok((result as { block: boolean }).block === true);
  });

  it("allows git status", async () => {
    const result = await runHook("bash", "git status");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git log --stash (not a stash subcommand)", async () => {
    const result = await runHook("bash", "git log --stash");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows non-bash tool with git stash payload", async () => {
    const result = await runHook("read", "git stash");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows codegen-log write narrating git stash", async () => {
    const result = await runHook(
      "bash",
      'codegen-log section --slug test --body @- <<EOF\n## developer-phoenix-backend Section\nDid NOT run git stash — used a scratch branch instead.\nEOF',
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("still blocks real git stash unchanged", async () => {
    const result = await runHook("bash", "git stash");
    assert.ok((result as { block: boolean }).block === true);
  });

  // ── quote-strip fail-closed regression (this pitch) ──────────────────────
  it("allows ssh remote git-stash payload (quoted)", async () => {
    const result = await runHook("bash", 'ssh box "git stash"');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git stash mentioned in quoted grep arg", async () => {
    const result = await runHook("bash", 'grep -n "git stash" notes.md');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("still blocks real unquoted git stash (fail-closed sanity)", async () => {
    const result = await runHook("bash", "git stash push -m wip");
    assert.ok((result as { block: boolean }).block === true);
  });
});
