/**
 * Tests for reviewer-guard hook.
 * Mirrors cases from reviewer-guard_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("reviewer-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, agentType: string) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../reviewer-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent("bash", command));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("allows Bash for reviewer-phoenix (reviewer-guard no longer gates Bash — see reviewer-bash-allowlist)", async () => {
    const result = await runHook("mix test", "reviewer-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Bash for reviewer-static (reviewer-guard no longer gates Bash — see reviewer-bash-allowlist)", async () => {
    const result = await runHook("npm run build", "reviewer-static");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Bash for developer-phoenix-backend", async () => {
    const result = await runHook("mix test", "developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
