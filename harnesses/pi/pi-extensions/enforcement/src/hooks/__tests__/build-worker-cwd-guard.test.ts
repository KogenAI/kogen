/**
 * Tests for build-worker-cwd-guard hook.
 * Mirrors cases from build-worker-cwd-guard_test.sh.
 */

import { describe, it, before, beforeEach, after } from "node:test";
import assert from "node:assert/strict";
import * as os from "node:os";
import * as path from "node:path";

// Synthetic apps root for test isolation — mirrors OCG_APPS_ROOT env var.
//
// Rooted under os.homedir(), NOT os.tmpdir(): the hook under test
// unconditionally allows any path starting with /tmp (see
// build-worker-cwd-guard.ts). On Linux os.tmpdir() resolves to /tmp, so a
// fixture rooted there would make the "blocks Read inside upload dir when
// OCG_USER_FILES_DIR unset (control)" assertion unreachable — the hook
// always allows it before the userFilesDir check runs.
const SYNTHETIC_APPS_ROOT = path.join(
  os.homedir(),
  ".ocg-test-apps-root",
);
const SYNTHETIC_PROJECT_DIR = path.join(SYNTHETIC_APPS_ROOT, "test-project");
const SYNTHETIC_USER_FILES_DIR = path.join(
  os.homedir(),
  ".ocg-test-user-files",
);

describe("build-worker-cwd-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    toolName: string,
    input: Record<string, string>,
    agentType = "",
    cwdOverride?: string,
  ) {
    process.env["AGENT_TYPE"] = agentType;
    if (cwdOverride !== undefined) {
      process.env["CWD"] = cwdOverride;
    }
    const { register } = await import("../build-worker-cwd-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({ toolName, toolCallId: "test-id", input });
  }

  before(() => {
    // Set OCG_APPS_ROOT so enforcement cases can reach the cwd boundary check.
    process.env["OCG_APPS_ROOT"] = SYNTHETIC_APPS_ROOT;
    process.env["CWD"] = SYNTHETIC_PROJECT_DIR;
  });

  after(() => {
    delete process.env["OCG_APPS_ROOT"];
    delete process.env["CWD"];
  });

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["OCG_USER_FILES_DIR"];
  });

  it("subagent Read of /etc/passwd allows (escape hatch)", async () => {
    const result = await runHook(
      "read",
      { file_path: "/etc/passwd" },
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Bash with /tmp reference (whitelist)", async () => {
    const result = await runHook("bash", { command: "cd /tmp && ls" }, "");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-orchestrator Read allows (not applicable)", async () => {
    const result = await runHook(
      "read",
      { file_path: "/etc/passwd" },
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Read inside OCG_USER_FILES_DIR (upload dir)", async () => {
    process.env["OCG_USER_FILES_DIR"] = SYNTHETIC_USER_FILES_DIR;
    try {
      const result = await runHook("read", { file_path: path.join(SYNTHETIC_USER_FILES_DIR, "ref.png") }, "");
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    } finally {
      delete process.env["OCG_USER_FILES_DIR"];
    }
  });

  it("blocks Read inside upload dir when OCG_USER_FILES_DIR unset (control)", async () => {
    delete process.env["OCG_USER_FILES_DIR"];
    const result = await runHook("read", { file_path: path.join(SYNTHETIC_USER_FILES_DIR, "ref.png") }, "");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("unset OCG_APPS_ROOT passes through (unknown boundary)", async () => {
    const saved = process.env["OCG_APPS_ROOT"];
    delete process.env["OCG_APPS_ROOT"];
    try {
      const result = await runHook("read", { file_path: "/etc/passwd" }, "");
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      if (saved !== undefined) process.env["OCG_APPS_ROOT"] = saved;
    }
  });
});
