/**
 * Tests for track-tool-failures hook.
 * Mirrors cases from track-tool-failures_test.sh.
 * Note: Pi hook event is tool_result — never blocks.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

function makeToolResultEvent(toolName: string, isError: boolean, agentType: string, sessionId = "sess-t1") {
  return {
    toolName,
    toolCallId: "test-id",
    output: { error: isError ? "command not found: mix" : undefined },
    isError,
    sessionId,
  };
}

describe("track-tool-failures", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function register(agentType: string) {
    process.env["AGENT_TYPE"] = agentType;
    const { register: reg } = await import("../track-tool-failures");
    reg(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
  }

  it("hook always exits without blocking (never blocks)", async () => {
    await register("developer-phoenix-backend");
    const result = await _capturedHandler(makeToolResultEvent("bash", true, "developer-phoenix-backend"));
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("non-error tool result does not block", async () => {
    await register("developer-phoenix-backend");
    const result = await _capturedHandler(makeToolResultEvent("edit", false, "developer-phoenix-backend", "sess-t2"));
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("orchestrator (empty agent) does not block", async () => {
    await register("");
    const result = await _capturedHandler(makeToolResultEvent("read", true, "", "sess-t3"));
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("empty error field handled gracefully (no crash)", async () => {
    await register("developer-phoenix-backend");
    const event = {
      toolName: "write",
      toolCallId: "test-id",
      output: {},
      isError: false,
      sessionId: "sess-t6",
    };
    const result = await _capturedHandler(event);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });
});
