/**
 * Tests for env-var-sample-consistency hook.
 * Mirrors cases from env-var-sample-consistency_test.sh.
 * Note: This hook runs git diff --cached which requires a real git repo.
 * Tests use simplified behavioral assertions.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeCommitEvent(command: string, agentType: string) {
  return { toolName: "bash", toolCallId: "test-id", input: { command } };
}

describe("env-var-sample-consistency", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, agentType = "committer") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../env-var-sample-consistency");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeCommitEvent(command, agentType));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("non-committer is not gated", async () => {
    const result = await runHook(
      'git commit -m "test"',
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-commit command passes through for committer", async () => {
    const result = await runHook("git status", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-bash tool passes through", async () => {
    process.env["AGENT_TYPE"] = "committer";
    const { register } = await import("../env-var-sample-consistency");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    const result = await _capturedHandler({
      toolName: "read",
      toolCallId: "test-id",
      input: { file_path: "/tmp/foo" },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
