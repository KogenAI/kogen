/**
 * Tests for committer-bash-allowlist hook.
 * Ports cases 1-13 and 19 from committer-tool-guard_test.sh / committer-tool-guard.test.ts.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeBashEvent(command: string) {
  return { toolName: "bash", toolCallId: "test-id", input: { command } };
}

function makeFileEvent(toolName: "write" | "edit", file_path: string) {
  return { toolName, toolCallId: "test-id", input: { file_path } };
}

describe("committer-bash-allowlist", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runBashHook(command: string, agentType = "committer") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../committer-bash-allowlist");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeBashEvent(command));
  }

  async function runFileHook(
    toolName: "write" | "edit",
    file_path: string,
    agentType = "committer",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../committer-bash-allowlist");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeFileEvent(toolName, file_path));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  // ── Bash: ALLOW (git commands and safe utilities) ──────────────────────

  it("allows git status for committer", async () => {
    const result = await runBashHook("git status");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git diff for committer", async () => {
    const result = await runBashHook("git diff");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git diff --cached for committer", async () => {
    const result = await runBashHook("git diff --cached");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git add -A for committer", async () => {
    const result = await runBashHook("git add -A");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it('allows git commit -m "msg" for committer', async () => {
    const result = await runBashHook('git commit -m "Add feature"');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git log for committer", async () => {
    const result = await runBashHook("git log --oneline -5");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git show for committer", async () => {
    const result = await runBashHook("git show HEAD");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows echo | wc -c for committer", async () => {
    const result = await runBashHook('echo -n "subject line" | wc -c');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Bash: DENY (build/test/package-manager commands) ──────────────────

  it("blocks make test for committer", async () => {
    const result = await runBashHook("make test");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks mix test for committer", async () => {
    const result = await runBashHook("mix test path/to/test.exs");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks npm run build for committer", async () => {
    const result = await runBashHook("npm run build");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks node script.js for committer", async () => {
    const result = await runBashHook("node script.js");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks pytest for committer", async () => {
    const result = await runBashHook("pytest tests/");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Pass-through: non-committer agents ────────────────────────────────

  it("passes through make test for non-committer (developer)", async () => {
    const result = await runBashHook("make test", "developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Bonus: git push/pull forbidden ────────────────────────────────────

  it("blocks git push for committer (not in allowlist)", async () => {
    const result = await runBashHook("git push origin main");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git pull for committer (not in allowlist)", async () => {
    const result = await runBashHook("git pull");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Pass-through: non-Bash tools ──────────────────────────────────────

  it("passes through Write tool for committer (different hook's job)", async () => {
    const result = await runFileHook("write", "lib/foo.ex");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
