/**
 * Tests for static-site-build-check hook.
 * Mirrors cases from static-site-build-check_test.sh.
 * Note: Pi session_shutdown event.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("static-site-build-check", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    agentType: string,
    cwd: string,
    stop_hook_active = false,
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../static-site-build-check");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "session_shutdown",
      toolCallId: "test-id",
      input: { cwd, stop_hook_active },
      agentType,
    });
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("stop_hook_active=true short-circuits (no block)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ssbc-test-"));
    try {
      const result = await runHook("developer-html", tmpDir, true);
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("non-static-site agent_type is no-op (no block)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ssbc-test-"));
    try {
      const result = await runHook("developer-phoenix-backend", tmpDir);
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("missing package.json (Hugo case) passes", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ssbc-hugo-"));
    try {
      const result = await runHook("developer-html", tmpDir);
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
