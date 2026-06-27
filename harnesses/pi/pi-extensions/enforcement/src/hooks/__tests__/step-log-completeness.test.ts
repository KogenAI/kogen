/**
 * Tests for step-log-completeness hook.
 * Mirrors cases from step-log-completeness_test.sh.
 * Note: Pi session_shutdown event — cannot block. Hook warns via stderr only.
 */

import { describe, it, before, after, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

describe("step-log-completeness", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  afterEach(() => {
    delete process.env["PI_ROLE"];
  });

  async function runHook(stop_hook_active = false, cwd = "/tmp") {
    const { register } = await import("../step-log-completeness");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "session_shutdown",
      toolCallId: "test-id",
      input: { cwd, stop_hook_active },
    });
  }

  it("stop_hook_active=true short-circuits without crash", async () => {
    const result = await runHook(true);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("no log found exits cleanly (no block)", async () => {
    const result = await runHook(false, "/tmp/no-such-dir-for-step-log-test");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("normal shutdown does not crash", async () => {
    const result = await runHook(false, "/tmp");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("does not warn when PI_ROLE=shape (investigative mode — build-runtime gate skipped)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "step-log-completeness-role-test-"));
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    const logFile = path.join(loggingDir, "20260101_120000_step1_test.md");
    fs.writeFileSync(
      logFile,
      "## developer-phoenix-backend Section\n\nSome content\n\n## dev-gate Section\n\nALL CLEAR ✅\n",
      "utf8",
    );
    const now = Date.now();
    fs.utimesSync(logFile, new Date(now), new Date(now));

    process.env["PI_ROLE"] = "shape";

    let stderrOutput = "";
    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (s: string) => {
      stderrOutput += s;
      return true;
    };
    try {
      await runHook(false, tmpDir);
    } finally {
      process.stderr.write = origWrite;
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }

    assert.ok(
      !stderrOutput.includes("WARNING"),
      "expected no WARNING when PI_ROLE=shape (investigative mode)",
    );
  });

  describe("empty-body content-floor (observe-only)", () => {
    let tmpDir: string;

    before(() => {
      tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "step-log-completeness-test-"));
      const loggingDir = path.join(tmpDir, "codegen", "logging");
      fs.mkdirSync(loggingDir, { recursive: true });
      // Write a recent log with developer section header but empty body
      const logFile = path.join(loggingDir, "20260101_120000_step1_test.md");
      fs.writeFileSync(
        logFile,
        "## developer-phoenix-backend Section\n\n",
        "utf8",
      );
      // Touch the file to ensure it's within the 60-min window
      const now = Date.now();
      fs.utimesSync(logFile, new Date(now), new Date(now));
    });

    after(() => {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    });

    it("empty developer section body — no throw, no block (warn-only path)", async () => {
      // REDUCED-FIDELITY: Pi cannot block. Assert only that the handler does not
      // throw and does not return a block decision (warn-only path).
      const result = await runHook(false, tmpDir);
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    });

    it("log with INTERRUPTED marker — no throw, death-marker skip fires", async () => {
      const loggingDir = path.join(tmpDir, "codegen", "logging");
      const logFile = path.join(loggingDir, "20260101_130000_step2_test.md");
      fs.writeFileSync(
        logFile,
        "## developer-phoenix-backend Section\n\n### INTERRUPTED ⚠️ — developer dropped; re-spawning (attempt 1/2)\n",
        "utf8",
      );
      const now = Date.now();
      fs.utimesSync(logFile, new Date(now), new Date(now));

      const result = await runHook(false, tmpDir);
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    });
  });
});
