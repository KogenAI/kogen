/**
 * Tests for committer-write-allowlist hook.
 * Ports cases 14-18 and 20 from committer-tool-guard_test.sh / committer-tool-guard.test.ts.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeBashEvent(command: string) {
  return { toolName: "bash", toolCallId: "test-id", input: { command } };
}

function makeFileEvent(toolName: "write" | "edit", file_path: string) {
  return { toolName, toolCallId: "test-id", input: { file_path } };
}

describe("committer-write-allowlist", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runFileHook(
    toolName: "write" | "edit",
    file_path: string,
    agentType = "committer",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../committer-write-allowlist");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeFileEvent(toolName, file_path));
  }

  async function runBashHook(command: string, agentType = "committer") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../committer-write-allowlist");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeBashEvent(command));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  // ── Write/Edit: ALLOW (canonical cycle log path) ─────────────────────

  it("allows Write to canonical cycle log", async () => {
    const result = await runFileHook(
      "write",
      "codegen/logging/20260607_120000_my-task_cycle.jsonl",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Edit to canonical cycle log", async () => {
    const result = await runFileHook(
      "edit",
      "codegen/logging/20260607_120000_my-task_cycle.jsonl",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Write/Edit: DENY (source files) ──────────────────────────────────

  it("blocks Write to hook ts file", async () => {
    const result = await runFileHook(
      "write",
      "harnesses/claude/hooks/reviewer-guard-session-log-write.ts",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks Edit to lib source file", async () => {
    const result = await runFileHook("edit", "lib/foo.ex");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks Write to scaffold.sh", async () => {
    const result = await runFileHook("write", "scaffold.sh");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Pass-through: non-committer agents ────────────────────────────────

  it("passes through source edit for non-committer (reviewer)", async () => {
    const result = await runFileHook("edit", "lib/foo.ex", "reviewer-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Pass-through: Bash tool ────────────────────────────────────────────

  it("passes through Bash tool for committer (different hook's job)", async () => {
    const result = await runBashHook("make test");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
