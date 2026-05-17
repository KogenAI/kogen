/**
 * Tests for track-subagent-edits hook.
 * Mirrors cases from track-subagent-edits_test.sh.
 * Note: Pi hook never blocks — telemetry only.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

function makeEvent(toolName: string, filePath: string, agentType: string, sessionId = "sess-001") {
  return { toolName, toolCallId: "test-id", input: { file_path: filePath }, sessionId };
}

describe("track-subagent-edits", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function register(agentType: string) {
    process.env["AGENT_TYPE"] = agentType;
    const { register: reg } = await import("../track-subagent-edits");
    reg(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
  }

  it("subagent Edit always allows (never blocks)", async () => {
    await register("developer-phoenix-backend");
    const result = await _capturedHandler(makeEvent("edit", "/app/lib/foo.ex", "developer-phoenix-backend"));
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("subagent Write always allows", async () => {
    await register("developer-phoenix-backend");
    const result = await _capturedHandler(makeEvent("write", "/app/lib/bar.ex", "developer-phoenix-backend", "sess-002"));
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("orchestrator Edit always allows (no blocking)", async () => {
    await register("");
    const result = await _capturedHandler(makeEvent("edit", "/app/codegen/logging/session.md", "", "sess-004"));
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("Bash tool always allows (not tracked)", async () => {
    await register("developer-phoenix-backend");
    const event = { toolName: "bash", toolCallId: "test-id", input: { command: "mix test" }, sessionId: "sess-005" };
    const result = await _capturedHandler(event);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });
});
