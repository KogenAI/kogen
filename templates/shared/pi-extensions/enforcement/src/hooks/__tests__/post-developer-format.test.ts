/**
 * Tests for post-developer-format hook.
 * Mirrors cases from post-developer-format_test.sh.
 * Note: Pi session_shutdown event; hook never blocks (telemetry + format side-effect).
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeShutdownEvent(agentType: string, cwd = "/tmp") {
  return {
    toolName: "session_shutdown",
    toolCallId: "test-id",
    input: { cwd, stop_hook_active: false },
    agentType,
  };
}

describe("post-developer-format", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(agentType: string, cwd = "/tmp") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../post-developer-format");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeShutdownEvent(agentType, cwd));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("non-developer agent_type is no-op (never blocks)", async () => {
    const result = await runHook("planner");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("developer-phoenix-backend shutdown does not block", async () => {
    const result = await runHook("developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("developer-phoenix-frontend shutdown does not block", async () => {
    const result = await runHook("developer-phoenix-frontend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
