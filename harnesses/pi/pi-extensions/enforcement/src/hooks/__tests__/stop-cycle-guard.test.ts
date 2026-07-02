/**
 * Tests for stop-cycle-guard hook.
 * Mirrors cases from stop-cycle-guard_test.sh.
 * Note: Pi session_shutdown event — cannot block (no decision:block for session_shutdown).
 * Hook writes to stderr only; tests verify no crash and output shape.
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

describe("stop-cycle-guard", { concurrency: 1 }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    agentType: string,
    stop_hook_active = false,
    cwd = "/tmp",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../stop-cycle-guard");
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

  it("stop_hook_active=true short-circuits without error", async () => {
    const result = await runHook("developer-phoenix-backend", true);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("committer agent type (cycle complete) does not crash", async () => {
    const result = await runHook("committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("reviewer agent type (mid-cycle) does not crash", async () => {
    const result = await runHook("reviewer-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("developer agent type (mid-cycle) does not crash", async () => {
    const result = await runHook("developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  // ── Per-step counter regression tests ─────────────────────────────────────

  it("per-step cap: step-A exhausted counter does not block step-B first stop", async () => {
    // Test (a): step-A counter at cap (2), then handler fires with step-B as active log.
    // Expected: step-B is a new step → count resets to 0 → warns (first block on B).
    const sessionId = "pi-test-per-step-a";
    const counterFile = path.join(
      os.tmpdir(),
      `claude-cycle-guard-${sessionId}.count`,
    );
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-scg-test-a-"));
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });

    // Create step-B log with developer section and no VE verdict → triggers warn path.
    const stepBFile = "20260614_120000_stepB_session.md";
    fs.writeFileSync(
      path.join(loggingDir, stepBFile),
      "# Step B\n## developer-phoenix-backend Section\nDone.\n",
    );

    // Pre-seed counter scoped to step-A at cap.
    fs.writeFileSync(counterFile, "stepA_session.md\n2\n");

    let stderrOutput = "";
    const originalStderr = process.stderr.write.bind(process.stderr);

    process.env["SESSION_ID"] = sessionId;
    process.env["CWD"] = tmpDir;
    process.env["PI_ROLE"] = "";
    process.env["CLAUDE_ROLE"] = "";

    try {
      process.stderr.write = (str: string | Uint8Array) => {
        stderrOutput += str.toString();
        return true;
      };

      await runHook("developer-phoenix-backend", false, tmpDir);

      // Step-B differs from step-A → count reset to 0 → first block → warning emitted.
      assert.ok(
        stderrOutput.includes("[pi-enforcement:stop-cycle-guard]"),
        `Expected warning on stderr, got: ${stderrOutput}`,
      );
      // Counter must NOT show the step-A scope any more (was reset to step-B).
      if (fs.existsSync(counterFile)) {
        const written = fs.readFileSync(counterFile, "utf8");
        assert.ok(
          !written.startsWith("stepA_session.md"),
          `Counter scope should have advanced to step-B, got: ${written}`,
        );
      }
    } finally {
      process.stderr.write = originalStderr as typeof process.stderr.write;
      delete process.env["SESSION_ID"];
      delete process.env["CWD"];
      delete process.env["AGENT_TYPE"];
      delete process.env["PI_ROLE"];
      delete process.env["CLAUDE_ROLE"];
      fs.rmSync(counterFile, { force: true });
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("empty active log keeps scope: in-progress count not reset when loggingDir empty", async () => {
    // Test (b): pre-seed counter (stepCur, count=1). loggingDir exists but has no .md files
    // → stepKey="" → keep scope → count stays 1 (not reset to 0 → still warns).
    const sessionId = "pi-test-empty-resolver";
    const counterFile = path.join(
      os.tmpdir(),
      `claude-cycle-guard-${sessionId}.count`,
    );
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "pi-scg-test-empty-"),
    );
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    // No .md files in loggingDir → logFiles=[] → stepKey="" → keep scope.

    // Pre-seed counter at count=1 for stepCur.
    fs.writeFileSync(counterFile, "stepCur_session.md\n1\n");

    process.env["SESSION_ID"] = sessionId;
    process.env["CWD"] = tmpDir;

    try {
      // Hook should return early (logFiles.length === 0 → return), but counter
      // must NOT be reset. Read counter after hook.
      await runHook("developer-phoenix-backend", false, tmpDir);

      // Counter must still exist and have count=1 (not reset, not incremented — early return).
      assert.ok(
        fs.existsSync(counterFile),
        "Counter file should still exist after early return (empty loggingDir)",
      );
      const written = fs.readFileSync(counterFile, "utf8").split("\n");
      assert.equal(
        written[0],
        "stepCur_session.md",
        "Scope line should be unchanged",
      );
      assert.equal(written[1], "1", "Count should be unchanged (still 1)");
    } finally {
      delete process.env["SESSION_ID"];
      delete process.env["CWD"];
      delete process.env["AGENT_TYPE"];
      fs.rmSync(counterFile, { force: true });
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("does not warn when PI_ROLE=shape (investigative mode — build-runtime gate skipped)", async () => {
    // Fixture: developer ran, session log present with developer but no VE verdict
    // — this would normally trigger a WARNING in build mode. With PI_ROLE=shape, silent skip.
    const sessionId = "pi-test-inv-skip";
    const counterFile = path.join(
      os.tmpdir(),
      `claude-cycle-guard-${sessionId}.count`,
    );
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-scg-inv-test-"));
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });

    // Log with developer section but no VE verdict — triggers warn path in build mode.
    const stepFile = "20260614_120000_step1_session.md";
    fs.writeFileSync(
      path.join(loggingDir, stepFile),
      "# Step 1\n## developer-phoenix-backend Section\nDone.\n",
    );

    process.env["SESSION_ID"] = sessionId;
    process.env["CWD"] = tmpDir;
    process.env["PI_ROLE"] = "shape";

    let stderrOutput = "";
    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (s: string) => {
      stderrOutput += s;
      return true;
    };

    try {
      await runHook("developer-phoenix-backend", false, tmpDir);
      assert.ok(
        !stderrOutput.includes("WARNING"),
        `expected no WARNING when PI_ROLE=shape, got: ${stderrOutput}`,
      );
    } finally {
      process.stderr.write = origWrite as typeof process.stderr.write;
      delete process.env["SESSION_ID"];
      delete process.env["CWD"];
      delete process.env["AGENT_TYPE"];
      delete process.env["PI_ROLE"];
      fs.rmSync(counterFile, { force: true });
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
