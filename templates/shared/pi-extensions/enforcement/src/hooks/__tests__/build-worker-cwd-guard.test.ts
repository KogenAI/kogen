/**
 * Tests for build-worker-cwd-guard hook.
 * Mirrors cases from build-worker-cwd-guard_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

describe("build-worker-cwd-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(toolName: string, input: Record<string, string>, agentType = "") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../build-worker-cwd-guard");
    register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
    return _capturedHandler({ toolName, toolCallId: "test-id", input });
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("subagent Read of /etc/passwd allows (escape hatch)", async () => {
    const result = await runHook("read", { file_path: "/etc/passwd" }, "planner");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Bash with /tmp reference (whitelist)", async () => {
    const result = await runHook("bash", { command: "cd /tmp && ls" }, "");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-orchestrator Read allows (not applicable)", async () => {
    const result = await runHook("read", { file_path: "/etc/passwd" }, "developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
