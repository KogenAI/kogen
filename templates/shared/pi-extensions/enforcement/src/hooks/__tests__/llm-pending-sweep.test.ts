/**
 * Tests for llm-pending-sweep hook.
 * Mirrors cases from llm-pending-sweep_test.sh.
 * Note: Pi session_shutdown event; hook never blocks.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("llm-pending-sweep", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function register() {
    const { register: reg } = await import("../llm-pending-sweep");
    reg(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
  }

  it("session_shutdown exits without blocking", async () => {
    await register();
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "llm-pending-test-"));
    fs.mkdirSync(path.join(tmpDir, "codegen", "llm-pending"), { recursive: true });
    try {
      const result = await _capturedHandler({
        toolName: "session_shutdown",
        toolCallId: "test-id",
        input: { cwd: tmpDir },
      });
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("fresh flag is preserved (hook never blocks)", async () => {
    await register();
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "llm-pending-fresh-"));
    const pendingDir = path.join(tmpDir, "codegen", "llm-pending");
    fs.mkdirSync(pendingDir, { recursive: true });
    const freshFlag = path.join(pendingDir, "fresh-session.flag");
    fs.writeFileSync(freshFlag, "agent_type=developer-phoenix-backend\n");
    try {
      const result = await _capturedHandler({
        toolName: "session_shutdown",
        toolCallId: "test-id",
        input: { cwd: tmpDir },
      });
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
      // Fresh flag should still exist (not swept)
      assert.ok(fs.existsSync(freshFlag));
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
