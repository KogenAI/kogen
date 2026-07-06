/**
 * Tests for curator-before-committer hook.
 * Mirrors cases from curator-before-committer_test.sh.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("curator-before-committer", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  let tmpDir: string;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "curator-test-"));
    fs.mkdirSync(path.join(tmpDir, "codegen", "logging"), { recursive: true });
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
  });

  function writeLog(filename: string, content: string): string {
    const logPath = path.join(tmpDir, "codegen", "logging", filename);
    fs.writeFileSync(logPath, content);
    return logPath;
  }

  function writeCycleState(state: string, stepLog: string): void {
    const dir = path.join(tmpDir, "codegen", "gate-pending");
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      path.join(dir, "cycle-state.json"),
      JSON.stringify({
        state,
        step_log: stepLog,
        session_id: "test-session",
        verdict: "",
        updated_at: new Date().toISOString(),
      }),
    );
  }

  async function runHook(subagentType: string) {
    process.env["CWD"] = tmpDir;
    const { register } = await import("../curator-before-committer");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "subagent",
      toolCallId: "test-id",
      input: { agent: subagentType },
    });
  }

  it("blocks committer when reviewer present, curator absent (cycle-state=REVIEWED)", async () => {
    const logPath = writeLog(
      "20260601_test_cycle.jsonl",
      JSON.stringify({
        ev: "role",
        role: "reviewer-phoenix",
        body: "**Verdict**: QUALITY APPROVED ✅",
      }) + "\n",
    );
    writeCycleState("REVIEWED", logPath);

    const result = await runHook("committer");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows committer when context-curator has run (cycle-state=CURATED)", async () => {
    const logPath = writeLog(
      "20260601_test_cycle.jsonl",
      [
        JSON.stringify({
          ev: "role",
          role: "reviewer-phoenix",
          body: "**Verdict**: QUALITY APPROVED ✅",
        }),
        JSON.stringify({
          ev: "role",
          role: "context-curator",
          body: "Files updated.",
        }),
      ].join("\n") + "\n",
    );
    writeCycleState("CURATED", logPath);

    const result = await runHook("committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows planner-phoenix unconditionally (not committer)", async () => {
    const logPath = writeLog(
      "20260601_test_cycle.jsonl",
      JSON.stringify({
        ev: "role",
        role: "reviewer-phoenix",
        body: "**Verdict**: QUALITY APPROVED ✅",
      }) + "\n",
    );
    writeCycleState("REVIEWED", logPath);

    const result = await runHook("planner-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows developer-phoenix-backend unconditionally (not committer)", async () => {
    const logPath = writeLog(
      "20260601_test_cycle.jsonl",
      JSON.stringify({
        ev: "role",
        role: "reviewer-phoenix",
        body: "**Verdict**: QUALITY APPROVED ✅",
      }) + "\n",
    );
    writeCycleState("REVIEWED", logPath);

    const result = await runHook("developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows reviewer-phoenix unconditionally (not committer)", async () => {
    const logPath = writeLog(
      "20260601_test_cycle.jsonl",
      JSON.stringify({
        ev: "role",
        role: "reviewer-phoenix",
        body: "**Verdict**: QUALITY APPROVED ✅",
      }) + "\n",
    );
    writeCycleState("REVIEWED", logPath);

    const result = await runHook("reviewer-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows committer when no cycle-state.json exists (fail-open: can't determine state)", async () => {
    writeLog(
      "20260601_test_cycle.jsonl",
      JSON.stringify({
        ev: "role",
        role: "reviewer-phoenix",
        body: "**Verdict**: QUALITY APPROVED ✅",
      }) + "\n",
    );
    // No cycle-state.json written.

    const result = await runHook("committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows committer when no log file exists (fail-open)", async () => {
    // No log files written — logging dir is empty
    process.env["CWD"] = tmpDir;

    const { register } = await import("../curator-before-committer");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    const result = await _capturedHandler({
      toolName: "subagent",
      toolCallId: "test-id",
      input: { agent: "committer" },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
