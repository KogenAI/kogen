/**
 * Tests for phoenix-dev-gate hook.
 * Mirrors cases from phoenix-dev-gate_test.sh.
 * Note: Pi session_shutdown event; simplified behavioral tests
 * (no full filesystem/git setup needed for basic gating logic).
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeShutdownEvent(agentType: string, cwd = "/tmp", stop_hook_active = false) {
  return {
    toolName: "session_shutdown",
    toolCallId: "test-id",
    input: { cwd, stop_hook_active },
    agentType,
  };
}

describe("phoenix-dev-gate", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(agentType: string, cwd = "/tmp", stop_hook_active = false) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../phoenix-dev-gate");
    register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
    return _capturedHandler(makeShutdownEvent(agentType, cwd, stop_hook_active));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("stop_hook_active=true short-circuits (no block)", async () => {
    const result = await runHook("developer-phoenix-backend", "/tmp", true);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-developer agent_type is a no-op (no block)", async () => {
    const result = await runHook("reviewer-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("committer agent_type is a no-op (no block)", async () => {
    const result = await runHook("committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
