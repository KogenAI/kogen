/**
 * Tests for stop-cycle-guard hook.
 * Mirrors cases from stop-cycle-guard_test.sh.
 * Note: Pi session_shutdown event — cannot block (no decision:block for session_shutdown).
 * Hook writes to stderr only; tests verify no crash and output shape.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

describe("stop-cycle-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(agentType: string, stop_hook_active = false, cwd = "/tmp") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../stop-cycle-guard");
    register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
    return _capturedHandler({
      toolName: "session_shutdown",
      toolCallId: "test-id",
      input: { cwd, stop_hook_active },
      agentType,
    });
  }

  it("stop_hook_active=true short-circuits without error", async () => {
    const result = await runHook("developer-phoenix-backend", true);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("committer agent type (cycle complete) does not crash", async () => {
    const result = await runHook("committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("reviewer agent type (mid-cycle) does not crash", async () => {
    const result = await runHook("reviewer-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("developer agent type (mid-cycle) does not crash", async () => {
    const result = await runHook("developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });
});
