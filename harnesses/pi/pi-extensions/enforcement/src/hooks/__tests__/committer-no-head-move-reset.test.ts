/**
 * Tests for committer-no-head-move-reset hook.
 * Mirrors cases from committer-no-head-move-reset_test.sh.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("committer-no-head-move-reset", { concurrency: 1 }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  let savedEnv: Record<string, string | undefined>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    command: string,
    agentType = "committer",
    extraEnv: Record<string, string> = {},
    toolName = "bash",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    for (const [k, v] of Object.entries(extraEnv)) {
      process.env[k] = v;
    }
    const { register } = await import("../committer-no-head-move-reset");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent(toolName, command));
  }

  beforeEach(() => {
    savedEnv = {
      AGENT_TYPE: process.env["AGENT_TYPE"],
      COMMITTER_ALLOW_MULTI: process.env["COMMITTER_ALLOW_MULTI"],
    };
    delete process.env["AGENT_TYPE"];
    delete process.env["COMMITTER_ALLOW_MULTI"];
  });

  afterEach(() => {
    for (const [k, v] of Object.entries(savedEnv)) {
      if (v === undefined) {
        delete process.env[k];
      } else {
        process.env[k] = v;
      }
    }
  });

  it("1. passes through for non-committer agent", async () => {
    const result = await runHook("git reset HEAD~1", "developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("2. passes through for non-bash tool", async () => {
    const result = await runHook("git reset HEAD~1", "committer", {}, "edit");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("3. allows when COMMITTER_ALLOW_MULTI=1 (escape hatch)", async () => {
    const result = await runHook("git reset HEAD~1", "committer", {
      COMMITTER_ALLOW_MULTI: "1",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("4. allows git status (not a reset)", async () => {
    const result = await runHook("git status", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("5. allows bare git reset", async () => {
    const result = await runHook("git reset", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("6. allows git reset HEAD", async () => {
    const result = await runHook("git reset HEAD", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("7. allows git reset -- path", async () => {
    const result = await runHook("git reset -- path.txt", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("8. allows git reset HEAD -- path", async () => {
    const result = await runHook("git reset HEAD -- path.txt", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("9. denies git reset HEAD~1", async () => {
    const result = await runHook("git reset HEAD~1", "committer");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("10. denies git reset --hard HEAD~1", async () => {
    const result = await runHook("git reset --hard HEAD~1", "committer");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("11. denies git reset --soft HEAD^", async () => {
    const result = await runHook("git reset --soft HEAD^", "committer");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("12. denies git reset <sha>", async () => {
    const result = await runHook(
      "git reset abc1234567890123456789012345678901234567",
      "committer",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("13. denies git reset --keep origin/develop", async () => {
    const result = await runHook("git reset --keep origin/develop", "committer");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("14. allows codegen-log write narrating git reset HEAD~1", async () => {
    const result = await runHook(
      'codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git reset HEAD~1 successfully.\nEOF',
      "committer",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
