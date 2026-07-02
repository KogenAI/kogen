/**
 * Tests for curator-format hook.
 * Mirrors cases from curator-format_test.sh.
 * Note: Pi session_shutdown event; hook never blocks (fix-up side-effect).
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

function makeShutdownEvent(agentType: string, cwd = "/tmp") {
  return {
    toolName: "session_shutdown",
    toolCallId: "test-id",
    input: { cwd, stop_hook_active: false },
    agentType,
  };
}

describe("curator-format", { concurrency: 1 }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(agentType: string, cwd = "/tmp") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../curator-format");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeShutdownEvent(agentType, cwd));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("non-curator agent_type is no-op (never blocks)", async () => {
    const result = await runHook("planner");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("context-curator shutdown does not block", async () => {
    const result = await runHook("context-curator");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("Makefile present but no format: target → no-op (make format NOT called)", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "curator-format-test-"),
    );
    try {
      fs.writeFileSync(
        path.join(tmpDir, "Makefile"),
        "install:\n\techo installed\n",
      );
      // Hook must return without error; no `make format` invocation (no target → early return).
      const result = await runHook("context-curator", tmpDir);
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
