/**
 * Tests for pitch-shipped-before-stop hook.
 * Mirrors cases from pitch-shipped-before-stop_test.sh.
 * Note: Pi session_shutdown is observe-only — warns to stderr, cannot block.
 * Tests verify no crash and correct warning behavior.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("pitch-shipped-before-stop", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  let tmpDir: string;
  let stderrOutput: string;
  const originalStderrWrite = process.stderr.write.bind(process.stderr);

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "pitch-shipped-before-stop-test-"),
    );
    fs.mkdirSync(path.join(tmpDir, "codegen", "logging"), { recursive: true });
    fs.mkdirSync(path.join(tmpDir, "codegen", "pitches", "ready"), {
      recursive: true,
    });
    fs.mkdirSync(path.join(tmpDir, "codegen", "pitches", "shipped"), {
      recursive: true,
    });

    stderrOutput = "";
    // Capture stderr
    (process.stderr as unknown as { write: (s: string) => boolean }).write = (
      s: string,
    ) => {
      stderrOutput += s;
      return true;
    };
  });

  afterEach(() => {
    // Restore stderr
    (process.stderr as unknown as { write: typeof originalStderrWrite }).write =
      originalStderrWrite;
    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
    delete process.env["SESSION_ID"];
    delete process.env["CLAUDE_ROLE"];
    delete process.env["PI_ROLE"];
    delete process.env["CODEGEN_NO_AUTOSHIP"];
  });

  function writeLog(content: string): void {
    const logPath = path.join(
      tmpDir,
      "codegen",
      "logging",
      "20260601_step1_test.md",
    );
    fs.writeFileSync(logPath, content);
  }

  function writePitchReady(name: string): void {
    fs.writeFileSync(
      path.join(tmpDir, "codegen", "pitches", "ready", name),
      "# Pitch\n",
    );
  }

  function writePitchShipped(name: string): void {
    fs.writeFileSync(
      path.join(tmpDir, "codegen", "pitches", "shipped", name),
      "# Pitch\n",
    );
  }

  async function runHook(sessionId = "test-session") {
    process.env["CWD"] = tmpDir;
    process.env["SESSION_ID"] = sessionId;
    const mod = await import("../pitch-shipped-before-stop");
    mod.register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "session_shutdown",
      toolCallId: "test-id",
      input: {},
    });
  }

  // ── Test 1: warns when committer-section present + pitch in ready/ ─────────
  it("warns when committer section present and pitch in ready/", async () => {
    writeLog("## committer Section\n\nCommitted.\n");
    writePitchReady("my-feature.md");
    await runHook("warn-sess-1");
    assert.ok(
      stderrOutput.includes("pitch-shipped-before-stop"),
      "expected warning on stderr",
    );
    assert.ok(stderrOutput.includes("my-feature.md"));
  });

  // ── Test 2: no warning when pitch in shipped/ (no ready/ pitch) ────────────
  it("does not warn when no pitches in ready/", async () => {
    writeLog("## committer Section\n\nCommitted.\n");
    writePitchShipped("my-feature.md");
    await runHook("shipped-sess-2");
    assert.ok(
      !stderrOutput.includes("pitch-shipped-before-stop"),
      "expected no warning",
    );
  });

  // ── Test 3: no warning when no step log ────────────────────────────────────
  it("does not warn when no step log exists", async () => {
    writePitchReady("my-feature.md");
    await runHook("no-log-sess-3");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 4: no warning when committer section absent ──────────────────────
  it("does not warn when committer section absent", async () => {
    writeLog("## reviewer-phoenix Section\n\nQUALITY APPROVED\n");
    writePitchReady("my-feature.md");
    await runHook("no-committer-sess-4");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 5: bypass CLAUDE_ROLE=dashboard-build ────────────────────────────
  it("bypasses when CLAUDE_ROLE=dashboard-build", async () => {
    process.env["CLAUDE_ROLE"] = "dashboard-build";
    writeLog("## committer Section\n\nCommitted.\n");
    writePitchReady("my-feature.md");
    await runHook("dashboard-sess-5");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 6: bypass CODEGEN_NO_AUTOSHIP=1 ──────────────────────────────────
  it("bypasses when CODEGEN_NO_AUTOSHIP is set", async () => {
    process.env["CODEGEN_NO_AUTOSHIP"] = "1";
    writeLog("## committer Section\n\nCommitted.\n");
    writePitchReady("my-feature.md");
    await runHook("no-autoship-sess-6");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 7: bypass PI_ROLE=dashboard-build ────────────────────────────────
  it("bypasses when PI_ROLE=dashboard-build", async () => {
    process.env["PI_ROLE"] = "dashboard-build";
    writeLog("## committer Section\n\nCommitted.\n");
    writePitchReady("my-feature.md");
    await runHook("pi-role-sess-7");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 8: retry cap stops warning at 2 ──────────────────────────────────
  it("stops warning after retry cap (count >= 2)", async () => {
    writeLog("## committer Section\n\nCommitted.\n");
    writePitchReady("my-feature.md");

    const counterFile = path.join(
      os.tmpdir(),
      "claude-autoship-guard-cap-sess-8.count",
    );
    fs.writeFileSync(counterFile, "2");

    await runHook("cap-sess-8");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning at cap");

    fs.rmSync(counterFile, { force: true });
  });

  // ── Test 9: increments counter on first warn ───────────────────────────────
  it("increments counter on first warning", async () => {
    writeLog("## committer Section\n\nCommitted.\n");
    writePitchReady("my-feature.md");

    const counterFile = path.join(
      os.tmpdir(),
      "claude-autoship-guard-count-sess-9.count",
    );
    fs.rmSync(counterFile, { force: true });

    await runHook("count-sess-9");
    const cnt = parseInt(
      fs.readFileSync(counterFile, "utf8").trim() || "0",
      10,
    );
    assert.equal(cnt, 1, "expected counter = 1 after first warning");
    fs.rmSync(counterFile, { force: true });
  });

  // ── Test 10: no warning when no pitches/ dir ──────────────────────────────
  it("does not crash when no pitches dir exists", async () => {
    writeLog("## committer Section\n\nCommitted.\n");
    // Remove ready/ dir
    fs.rmSync(path.join(tmpDir, "codegen", "pitches", "ready"), {
      recursive: true,
      force: true,
    });
    await runHook("no-pitches-sess-10");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 11: second warn still fires before cap ───────────────────────────
  it("warns again at count=1 (below cap)", async () => {
    writeLog("## committer Section\n\nCommitted.\n");
    writePitchReady("my-feature.md");

    const counterFile = path.join(
      os.tmpdir(),
      "claude-autoship-guard-second-warn-sess-11.count",
    );
    fs.writeFileSync(counterFile, "1");

    await runHook("second-warn-sess-11");
    assert.ok(stderrOutput.includes("WARNING"), "expected warning at count=1");
    fs.rmSync(counterFile, { force: true });
  });

  // ── Test 12: no warning when no logging dir ───────────────────────────────
  it("does not crash when no logging dir exists", async () => {
    fs.rmSync(path.join(tmpDir, "codegen", "logging"), {
      recursive: true,
      force: true,
    });
    writePitchReady("my-feature.md");
    await runHook("no-logging-sess-12");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 13: warning message names the pitch basename ─────────────────────
  it("warning message includes pitch basename", async () => {
    writeLog("## committer Section\n\nCommitted.\n");
    writePitchReady("orchestrator-discipline.md");
    await runHook("name-check-sess-13");
    assert.ok(
      stderrOutput.includes("orchestrator-discipline.md"),
      "expected pitch basename in warning",
    );
  });

  // ── Test 14: does not block (observe-only) ────────────────────────────────
  it("returns null/undefined (observe-only — cannot block)", async () => {
    writeLog("## committer Section\n\nCommitted.\n");
    writePitchReady("my-feature.md");
    const result = await runHook("observe-sess-14");
    // session_shutdown handlers must NOT return a block result
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
      "Pi session_shutdown should not return block",
    );
  });
});
