/**
 * Tests for reviewer-guard-session-log-write hook.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, filePath: string) {
  return { toolName, toolCallId: "test-id", input: { file_path: filePath } };
}

describe("reviewer-guard-session-log-write", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(toolName: string, filePath: string, agentType: string) {
    const previous = process.env["AGENT_TYPE"];
    process.env["AGENT_TYPE"] = agentType;
    try {
      const { register } = await import("../reviewer-guard-session-log-write");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      return await _capturedHandler(makeToolCallEvent(toolName, filePath));
    } finally {
      if (previous === undefined) {
        delete process.env["AGENT_TYPE"];
      } else {
        process.env["AGENT_TYPE"] = previous;
      }
    }
  }

  it("allows write to a canonical session log for reviewer-phoenix", async () => {
    const result = await runHook(
      "write",
      "codegen/logging/20260715_120000_my-slug_cycle.jsonl",
      "reviewer-phoenix",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks write to a non-log file for reviewer-phoenix", async () => {
    const result = await runHook("write", "lib/foo.ex", "reviewer-phoenix");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks edit to a non-log file for reviewer-static", async () => {
    const result = await runHook("edit", "assets/app.css", "reviewer-static");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows write to lib/ for a non-reviewer role (pass-through)", async () => {
    const result = await runHook(
      "write",
      "lib/foo.ex",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
