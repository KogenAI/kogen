/**
 * Tests for developer-static-no-build-output-probe hook.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, filePath: string) {
  return { toolName, toolCallId: "test-id", input: { file_path: filePath } };
}

describe("developer-static-no-build-output-probe", () => {
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
      const { register } = await import(
        "../developer-static-no-build-output-probe"
      );
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

  it("blocks read of public/ for developer-static", async () => {
    const result = await runHook("read", "public/index.html", "developer-static");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks grep of dist/ for developer-static", async () => {
    const result = await runHook("grep", "dist/app.js", "developer-static");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows read of src/ source for developer-static", async () => {
    const result = await runHook("read", "src/App.tsx", "developer-static");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows read of public/ for a different role (pass-through)", async () => {
    const result = await runHook(
      "read",
      "public/index.html",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
