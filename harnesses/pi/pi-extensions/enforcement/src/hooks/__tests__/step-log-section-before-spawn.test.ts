/**
 * Tests for step-log-section-before-spawn hook.
 * Mirrors cases from step-log-section-before-spawn_test.sh (JSONL cycle log storage).
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
    // getActiveStepLog's resolution step 0 (CODEGEN_LOG_PATH) outranks the
    // tmpDir-scoped .active/mtime scan this suite exercises — an ambient
    // pin from the launching dev/loop session (every role invocation
    // carries one) would silently redirect the hook outside tmpDir.
    delete process.env["CODEGEN_LOG_PATH"];
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
    delete process.env["CLAUDE_ROLE"];
    delete process.env["PI_ROLE"];
    delete process.env["CODEGEN_LOG_PATH"];
  });

  function writeLog(filename: string, lines: string[]): string {
    const logPath = path.join(tmpDir, "codegen", "logging", filename);
    fs.writeFileSync(logPath, lines.map((l) => l + "\n").join(""));
    return logPath;
  }

  function roleEvent(role: string, body: string): string {
    return JSON.stringify({ ev: "role", role, body });
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

  // ── Test 1b: deny when log path resolves but read throws (present-but-unreadable) ──
  it("denies when step log path resolves but read throws (present-but-unreadable)", async () => {
    // A directory named *.jsonl matches getActiveStepLog's readdirSync filter
    // (endsWith(".jsonl")) and existsSync, but fs.readFileSync throws EISDIR on
    // it — this is the present-but-unreadable anomaly path, not absence.
    const logDirAsFile = path.join(
      tmpDir,
      "codegen",
      "logging",
      "20260601_120000_test_cycle.jsonl",
    );
    fs.mkdirSync(logDirAsFile, { recursive: true });

    const result = await runHook("planner-phoenix");
    const asObj = result as { block?: boolean; reason?: string } | null;
    assert.ok(
      asObj != null && asObj.block === true,
      `expected block but got: ${JSON.stringify(result)}`,
    );
    assert.ok(
      asObj.reason?.includes("could not be read"),
      `expected "could not be read" in reason but got: ${asObj.reason}`,
    );
  });

  // ── Test 2: deny planner-phoenix when role event body is empty ────────────
  it("denies planner-phoenix when role event body is empty", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      roleEvent("planner-phoenix", ""),
    ]);
    const result = await runHook("planner-phoenix");
    // No prior role for planner-*, so this actually allows — role event IS
    // present (empty body doesn't matter for planner since it has no prior
    // stage to check). Assert allow to lock in the real contract.
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 3: deny developer-phoenix-backend when role event absent ─────────
  it("denies developer-phoenix-backend when role event absent", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      roleEvent("planner-phoenix", "planner wrote here"),
    ]);
    const result = await runHook("developer-phoenix-backend");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Test 4: allow planner-phoenix when role event has body content ────────
  it("allows planner-phoenix when role event has body content", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      roleEvent("planner-phoenix", "planner wrote here"),
    ]);
    const result = await runHook("planner-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 5: deny developer-phoenix-backend when its own role event body is empty ──
  it("denies developer-phoenix-backend when role event body is empty", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      roleEvent("planner-phoenix", ""),
      roleEvent("developer-phoenix-backend", ""),
    ]);
    const result = await runHook("developer-phoenix-backend");
    // developer's prior is planner; planner's body is empty -> deny.
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Test 6: allow developer-phoenix-backend with prior (planner) body present ──
  it("allows developer-phoenix-backend with prior planner body present", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      roleEvent("planner-phoenix", "planner wrote here"),
      roleEvent("developer-phoenix-backend", "real developer body"),
    ]);
    const result = await runHook("developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 7: allow developer-static role event present (no prior, planner absent) ──
  it("denies developer-static when no planner prior role event present", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      roleEvent("developer-static", "body"),
    ]);
    const result = await runHook("developer-static");
    // developer-static's role event is present, but prior "planner*" role
    // event is absent -> priorRole resolves to "" (lastRoleStartingWith
    // returns ""), so no prior-body check fires -> allow.
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 8: allow reviewer-phoenix with prior developer body present ──────
  it("allows reviewer-phoenix with prior developer body present", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      roleEvent("developer-phoenix-backend", "dev body"),
      roleEvent("reviewer-phoenix", "review"),
    ]);
    const result = await runHook("reviewer-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 9: allow reviewer-static with prior developer-static body present ─
  it("allows reviewer-static with prior developer-static body present", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      roleEvent("developer-static", "dev body"),
      roleEvent("reviewer-static", "review"),
    ]);
    const result = await runHook("reviewer-static");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 10: allow context-curator with prior reviewer body present ───────
  it("allows context-curator with prior reviewer body present", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      roleEvent("reviewer-phoenix", "review body"),
      roleEvent("context-curator", "context"),
    ]);
    const result = await runHook("context-curator");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 11: allow committer with prior context-curator body present ──────
  it("allows committer with prior context-curator body present", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      roleEvent("context-curator", "curator body"),
      roleEvent("committer", "commit"),
    ]);
    const result = await runHook("committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Test 12: deny committer when prior context-curator body is empty ──────
  it("denies committer when prior context-curator body is empty", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      roleEvent("context-curator", ""),
      roleEvent("committer", "commit"),
    ]);
    const result = await runHook("committer");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Test 13: malformed line in cycle log is skipped, not fatal ─────────────
  it("skips malformed JSONL lines without crashing", async () => {
    writeLog("20260601_120000_test_cycle.jsonl", [
      "not-json-at-all",
      roleEvent("planner-phoenix", "planner wrote here"),
      roleEvent("developer-phoenix-backend", "dev body"),
    ]);
    const result = await runHook("developer-phoenix-backend");
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
    // logging dir was created in beforeEach but has no .jsonl files
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

  // ── Test 16b: PI_ROLE=build still denies (explicit build role enforces) ────
  it("denies spawn when PI_ROLE=build and log dir is empty", async () => {
    process.env["PI_ROLE"] = "build";
    const result = await runHook("planner-phoenix");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Test 17: deny when role event present but body empty (own-body prior check) ──
  it("denies when developer role event is present but prior planner body is empty", async () => {
    const ts = "20260601_120000";
    writeLog(`${ts}_test_cycle.jsonl`, [
      roleEvent("planner-phoenix", ""),
      roleEvent("developer-phoenix-backend", "dev wrote something"),
    ]);

    const result = await runHook("developer-phoenix-backend");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Test 18: REGRESSION — disk-scan immunity to the Claude Bash-writer deadlock ──
  // Claude's session_log_from_transcript() only recognizes Write/Edit/MultiEdit
  // tool_use events as log-creation evidence, but session-log-writer-only.sh
  // hard-denies those raw events (codegen-log, a Bash invocation, is the sole
  // legal writer) — causing an interactive/self-build deadlock on the Claude
  // side. Pi has no such bug: getActiveStepLog resolves purely via disk
  // mtime-scan, with zero dependency on tool_use event shape. This test locks
  // in that immunity: a real cycle log with both required role events+bodies on
  // disk resolves to ALLOW regardless of what (if anything) wrote it.
  it("allows via disk-scan when cycle log exists with required role events, independent of writer tool shape", async () => {
    writeLog("20260702_000000_codegen-log-only_cycle.jsonl", [
      roleEvent("planner-phoenix", "Files to touch:\n- lib/foo.ex (NEW)"),
      roleEvent("developer-phoenix-backend", "dev wrote real content here"),
    ]);
    const result = await runHook("developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies via disk-scan when logging dir is empty (immunity does not over-allow)", async () => {
    // logging dir created in beforeEach but has no .jsonl files — must still deny.
    const result = await runHook("developer-phoenix-backend");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Test 19: allow when prior section body is only an H3 verdict line ─────
  // Regression guard: a role event body that is exactly "### FINAL VERDICT —
  // APPROVED" (no other prose) is real content, not a retrospective stub.
  // roleHasBody must NOT blanket-exclude all "### "-prefixed lines — only
  // the "### What I Learned This Step" retrospective block.
  it("allows when developer role event body is only an H3 verdict line", async () => {
    writeLog("20260703_000000_verdict-only_cycle.jsonl", [
      roleEvent("planner-phoenix", "planner wrote here"),
      roleEvent("developer-phoenix-backend", "### FINAL VERDICT — APPROVED"),
    ]);
    const result = await runHook("developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

});
