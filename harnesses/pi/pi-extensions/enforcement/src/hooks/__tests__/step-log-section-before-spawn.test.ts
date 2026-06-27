/**
 * Tests for step-log-section-before-spawn hook.
 * Mirrors cases from step-log-section-before-spawn_test.sh.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("step-log-section-before-spawn", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  let tmpDir: string;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "step-log-section-before-spawn-test-"),
    );
    fs.mkdirSync(path.join(tmpDir, "codegen", "logging"), { recursive: true });
    delete process.env["CLAUDE_ROLE"];
    delete process.env["PI_ROLE"];
    delete process.env["CWD"];
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
    delete process.env["CLAUDE_ROLE"];
    delete process.env["PI_ROLE"];
  });

  function writeLog(filename: string, content: string): string {
    const logPath = path.join(tmpDir, "codegen", "logging", filename);
    fs.writeFileSync(logPath, content);
    return logPath;
  }

  async function runHook(subagentType: string) {
    process.env["CWD"] = tmpDir;
    // Use a fresh import per test via cache-busting
    const mod = await import("../step-log-section-before-spawn");
    mod.register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "subagent",
      toolCallId: "test-id",
      input: { agent: subagentType },
    });
  }

  // ── Test 1: deny when no step log in logging dir ──────────────────────────
  it("denies when no step log exists (planner-phoenix)", async () => {
    // logging dir is empty
    const result = await runHook("planner-phoenix");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Test 2: deny planner-phoenix when ## Plan header absent ───────────────
  it("denies planner-phoenix when ## Plan header absent", async () => {
    writeLog(
      "20260601_step1_test.md",
      ["# Step 1", "", "## Version Stamp", "", "context: abc"].join("\n"),
    );
    const result = await runHook("planner-phoenix");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Test 3: deny developer-phoenix-backend when section header absent ──────
  it("denies developer-phoenix-backend when section header absent", async () => {
    writeLog(
      "20260601_step1_test.md",
      ["# Step 1", "", "## Plan", "", "planner wrote here"].join("\n"),
    );
    const result = await runHook("developer-phoenix-backend");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Test 4: allow planner-phoenix when ## Plan header present ─────────────
  it("allows planner-phoenix when ## Plan header present (even empty)", async () => {
    writeLog(
      "20260601_step1_test.md",
      ["# Step 1", "", "## Plan", ""].join("\n"),
    );
    const result = await runHook("planner-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 5: allow developer-phoenix-backend with header present ────────────
  it("allows developer-phoenix-backend with section header present", async () => {
    writeLog(
      "20260601_step1_test.md",
      ["## Plan", "", "## developer-phoenix-backend Section", ""].join("\n"),
    );
    const result = await runHook("developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 6: allow developer-phoenix-frontend with header present ───────────
  it("allows developer-phoenix-frontend with section header present", async () => {
    writeLog(
      "20260601_step1_test.md",
      ["## developer-phoenix-frontend Section", ""].join("\n"),
    );
    const result = await runHook("developer-phoenix-frontend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 7: allow developer-static with header present ────────────────────
  it("allows developer-static with section header present", async () => {
    writeLog(
      "20260601_step1_test.md",
      ["## developer-static Section", ""].join("\n"),
    );
    const result = await runHook("developer-static");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 8: allow reviewer-phoenix with header present ────────────────────
  it("allows reviewer-phoenix with section header present", async () => {
    writeLog(
      "20260601_step1_test.md",
      ["## reviewer-phoenix Section", ""].join("\n"),
    );
    const result = await runHook("reviewer-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 9: allow reviewer-static with header present ─────────────────────
  it("allows reviewer-static with section header present", async () => {
    writeLog(
      "20260601_step1_test.md",
      ["## reviewer-static Section", ""].join("\n"),
    );
    const result = await runHook("reviewer-static");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 10: allow context-curator with header present ────────────────────
  it("allows context-curator with section header present", async () => {
    writeLog(
      "20260601_step1_test.md",
      ["## context-curator Section", ""].join("\n"),
    );
    const result = await runHook("context-curator");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 11: allow committer with header present ───────────────────────────
  it("allows committer with section header present", async () => {
    writeLog("20260601_step1_test.md", ["## committer Section", ""].join("\n"));
    const result = await runHook("committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 12: allow developer-static (unified static stack) ────────────────────
  it("allows developer-static (test 12) with section header present", async () => {
    writeLog(
      "20260601_step1_test.md",
      ["## developer-static Section", ""].join("\n"),
    );
    const result = await runHook("developer-static");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 13: allow developer-static (unified static stack) ────────────────────
  it("allows developer-static (test 13) with section header present", async () => {
    writeLog(
      "20260601_step1_test.md",
      ["## developer-static Section", ""].join("\n"),
    );
    const result = await runHook("developer-static");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 14: non-subagent tool is not intercepted ─────────────────────────
  it("ignores non-subagent tool calls", async () => {
    process.env["CWD"] = tmpDir;
    // logging dir empty — would deny if it were a subagent
    const mod = await import("../step-log-section-before-spawn");
    mod.register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    const result = await _capturedHandler({
      toolName: "bash", // not "subagent"
      toolCallId: "test-id",
      input: { command: "ls" },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 15: deny when logging dir is empty (fail-closed-on-absent regression guard) ──
  // Pi uses disk mtime-scan (getActiveStepLog), not transcript-scan. A denied
  // Write never creates a file → loggingDir is empty → getActiveStepLog returns
  // null → deny. This test locks in that the Pi path stays fail-closed-on-absent.
  it("denies when logging dir is empty (no files on disk)", async () => {
    // logging dir was created in beforeEach but has no .md files
    const result = await runHook("planner-phoenix");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Test 16: allow PI_ROLE=shape with empty log dir (investigative bypass) ──
  it("allows spawn when PI_ROLE=shape regardless of missing log", async () => {
    process.env["PI_ROLE"] = "shape";
    // logging dir empty — would deny without bypass
    const result = await runHook("planner-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 17: observe-only warning when section header present but body empty ──
  // Pi hook is reduced-fidelity (no transcript). When '## <type> Section' exists
  // with empty body, it emits a stderr warning but does NOT block (observe-only).
  // Full block enforcement lives in the Bash Claude hook.
  it("emits observe-only warning (not block) when section header present but body empty", async () => {
    const ts = "20260601_120000";
    // Section exists but body is truly empty: only blank lines remain
    // after stripping the retrospective header. The "- nothing notable"
    // content under ### What I Learned is NOT skipped by the scanner —
    // only the ### header line itself is skipped. So use a bare empty body.
    writeLog(
      `${ts}_step1_test.md`,
      [
        "# Step 1",
        "",
        "## Plan",
        "",
        "planner wrote a real plan here",
        "",
        "## developer-phoenix-backend Section",
        "",
      ].join("\n"),
    );

    let stderrOutput = "";
    const origStderrWrite = process.stderr.write.bind(process.stderr);
    // Capture stderr at test-body scope; restore in finally on both paths
    process.stderr.write = (chunk: string | Uint8Array): boolean => {
      stderrOutput += chunk.toString();
      return true;
    };

    let result: unknown;
    try {
      result = await runHook("developer-phoenix-backend");
    } finally {
      process.stderr.write = origStderrWrite;
    }

    // Must NOT block (observe-only)
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
      "hook must not block on empty-body section (observe-only)",
    );
    // Must emit warning mentioning observe-only or body is empty
    assert.match(
      stderrOutput,
      /observe-only|body is empty/,
      "expected observe-only warning in stderr",
    );
  });
});
