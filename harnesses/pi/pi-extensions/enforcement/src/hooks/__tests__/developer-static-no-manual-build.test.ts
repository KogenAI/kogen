/**
 * Tests for developer-static-no-manual-build hook.
 * Mirrors cases from developer-static-no-manual-build_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("developer-static-no-manual-build", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(toolName: string, command: string, agentType: string) {
    const previous = process.env["AGENT_TYPE"];
    process.env["AGENT_TYPE"] = agentType;
    try {
      const { register } = await import("../developer-static-no-manual-build");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      return await _capturedHandler(makeToolCallEvent(toolName, command));
    } finally {
      if (previous === undefined) {
        delete process.env["AGENT_TYPE"];
      } else {
        process.env["AGENT_TYPE"] = previous;
      }
    }
  }

  it("blocks npm run build for developer-static", async () => {
    const result = await runHook("bash", "npm run build", "developer-static");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks vite build for developer-static", async () => {
    const result = await runHook("bash", "vite build", "developer-static");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git status for developer-static", async () => {
    const result = await runHook("bash", "git status", "developer-static");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows npm run build for a different role (pass-through)", async () => {
    const result = await runHook(
      "bash",
      "npm run build",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows codegen-log write narrating npm run build", async () => {
    const result = await runHook(
      "bash",
      "codegen-log section --slug test --body @- <<EOF\n## developer-static Section\nDid NOT run npm run build manually — gate runs it on SubagentStop.\nEOF",
      "developer-static",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("still blocks real npm run build unchanged", async () => {
    const result = await runHook("bash", "npm run build", "developer-static");
    assert.ok((result as { block?: boolean }).block === true);
  });
});
