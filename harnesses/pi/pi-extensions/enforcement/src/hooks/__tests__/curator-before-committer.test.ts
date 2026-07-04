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

  it("blocks committer when reviewer present, curator absent", async () => {
    writeLog(
      "20260601_step1_test.md",
      [
        "## developer-phoenix-backend Section",
        "",
        "result here",
        "",
        "## dev-gate Section",
        "",
        "ALL CLEAR ✅",
        "",
        "## reviewer-phoenix Section",
        "",
        "**Verdict**: QUALITY APPROVED ✅",
      ].join("\n"),
    );

    const result = await runHook("committer");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows committer when context-curator section present", async () => {
    writeLog(
      "20260601_step1_test.md",
      [
        "## developer-phoenix-backend Section",
        "",
        "result here",
        "",
        "## dev-gate Section",
        "",
        "ALL CLEAR ✅",
        "",
        "## reviewer-phoenix Section",
        "",
        "**Verdict**: QUALITY APPROVED ✅",
        "",
        "## context-curator Section",
        "",
        "Files updated.",
      ].join("\n"),
    );

    const result = await runHook("committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows planner-phoenix unconditionally (not committer)", async () => {
    writeLog(
      "20260601_step1_test.md",
      [
        "## reviewer-phoenix Section",
        "",
        "**Verdict**: QUALITY APPROVED ✅",
      ].join("\n"),
    );

    const result = await runHook("planner-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows developer-phoenix-backend unconditionally (not committer)", async () => {
    writeLog(
      "20260601_step1_test.md",
      [
        "## reviewer-phoenix Section",
        "",
        "**Verdict**: QUALITY APPROVED ✅",
      ].join("\n"),
    );

    const result = await runHook("developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows reviewer-phoenix unconditionally (not committer)", async () => {
    writeLog(
      "20260601_step1_test.md",
      [
        "## reviewer-phoenix Section",
        "",
        "**Verdict**: QUALITY APPROVED ✅",
      ].join("\n"),
    );

    const result = await runHook("reviewer-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks committer when log path resolves but read throws (present-but-unreadable)", async () => {
    // A directory named *.md matches getActiveStepLog's readdirSync filter
    // (endsWith(".md")) and existsSync, but fs.readFileSync throws EISDIR on
    // it — this is the present-but-unreadable anomaly path, not absence.
    const logDirAsFile = path.join(
      tmpDir,
      "codegen",
      "logging",
      "20260601_step1_test.md",
    );
    fs.mkdirSync(logDirAsFile, { recursive: true });

    const result = await runHook("committer");
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
