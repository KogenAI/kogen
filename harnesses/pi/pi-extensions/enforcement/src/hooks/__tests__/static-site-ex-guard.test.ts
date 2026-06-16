/**
 * Tests for static-site-ex-guard hook.
 * Mirrors cases from static-site-ex-guard_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

describe("static-site-ex-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(filePath: string, agentType = "developer-static") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../static-site-ex-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "write",
      toolCallId: "test-id",
      input: { file_path: filePath, content: "x" },
    });
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("blocks .ex file write for developer-static", async () => {
    const result = await runHook("/app/lib/my_app/context.ex");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows .js file write for developer-static", async () => {
    const result = await runHook("/app/assets/app.js");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks .exs file write for developer-static", async () => {
    const result = await runHook("/app/priv/repo/migrations/foo.exs");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows .ex file write for developer-phoenix-backend (not static site)", async () => {
    const result = await runHook(
      "/app/lib/my_app/context.ex",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
