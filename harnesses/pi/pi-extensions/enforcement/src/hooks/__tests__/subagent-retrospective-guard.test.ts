/**
 * Tests for subagent-retrospective-guard hook.
 * Mirrors cases from subagent-retrospective-guard_test.sh.
 * Note: Pi session_shutdown is observe-only — warns to stderr, cannot block.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("subagent-retrospective-guard", { concurrency: false }, () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "subagent-retrospective-guard-test-"),
    );
    fs.mkdirSync(path.join(tmpDir, "codegen", "logging"), { recursive: true });
    process.env["CWD"] = tmpDir;
    delete process.env["AGENT_TYPE"];
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
    delete process.env["AGENT_TYPE"];
  });

  function writeLog(content: string): void {
    fs.writeFileSync(
      path.join(
        tmpDir,
        "codegen",
        "logging",
        "20260601_120000_test_session.md",
      ),
      content,
    );
  }

  async function runHook(agentType: string): Promise<string> {
    process.env["AGENT_TYPE"] = agentType;

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../subagent-retrospective-guard");
    mod.register(
      localMockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );

    let stderrOutput = "";
    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (s: string) => {
      stderrOutput += s;
      return true;
    };
    try {
      await capturedHandler!({
        toolName: "session_shutdown",
        toolCallId: "test-id",
        input: {},
      });
    } finally {
      process.stderr.write = origWrite;
    }
    return stderrOutput;
  }

  // Skip: agent not in matcher set
  it("skips for committer (not in matcher)", async () => {
    writeLog("## committer Section\n\nDone.\n");
    const stderr = await runHook("committer");
    assert.ok(!stderr.includes("subagent-retrospective-guard"), "expected no warning");
  });

  it("skips for context-curator (not in matcher)", async () => {
    const stderr = await runHook("context-curator");
    assert.ok(!stderr.includes("subagent-retrospective-guard"), "expected no warning");
  });

  it("skips for orchestrator (empty AGENT_TYPE)", async () => {
    const stderr = await runHook("");
    assert.ok(!stderr.includes("subagent-retrospective-guard"), "expected no warning");
  });

  // Skip: no step log
  it("skips when no step log exists (fail-open)", async () => {
    fs.rmSync(path.join(tmpDir, "codegen", "logging"), {
      recursive: true,
      force: true,
    });
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(!stderr.includes("subagent-retrospective-guard"), "expected no warning");
  });

  // Skip: section header absent (defensive)
  it("skips when agent section header not found in log", async () => {
    writeLog("## some-other Section\n\nContent.\n");
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(!stderr.includes("subagent-retrospective-guard"), "expected no warning");
  });

  // Valid: retrospective present with content
  it("does not warn when developer-phoenix-backend has retrospective with bullet", async () => {
    const content = [
      "## developer-phoenix-backend Section",
      "",
      "Work done.",
      "",
      "### What I Learned This Step",
      "",
      "- nothing notable",
      "",
    ].join("\n");
    writeLog(content);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("does not warn for developer-phoenix-frontend with retrospective", async () => {
    const content = [
      "## developer-phoenix-frontend Section",
      "",
      "Work done.",
      "",
      "### What I Learned This Step",
      "",
      "- [local] something specific",
      "",
    ].join("\n");
    writeLog(content);
    const stderr = await runHook("developer-phoenix-frontend");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("does not warn for reviewer-phoenix with retrospective", async () => {
    const content = [
      "## reviewer-phoenix Section",
      "",
      "Review done.",
      "",
      "### What I Learned This Step",
      "",
      "- nothing notable",
      "",
    ].join("\n");
    writeLog(content);
    const stderr = await runHook("reviewer-phoenix");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  // Valid: planner-phoenix under ## Plan
  it("does not warn for planner-phoenix with retrospective under ## Plan", async () => {
    const content = [
      "## Plan",
      "",
      "Plan content here.",
      "",
      "### What I Learned This Step",
      "",
      "- [local] planner finding",
      "",
      "## developer-phoenix-backend Section",
      "",
      "stub",
    ].join("\n");
    writeLog(content);
    const stderr = await runHook("planner-phoenix");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  // Warn: retrospective header missing
  it("warns when developer-phoenix-backend section lacks retrospective header", async () => {
    const content = [
      "## developer-phoenix-backend Section",
      "",
      "Work done.",
      "",
      "**Result**: complete.",
      "",
    ].join("\n");
    writeLog(content);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(
      stderr.includes("subagent-retrospective-guard"),
      "expected warning",
    );
    assert.ok(stderr.includes("missing the '### What I Learned This Step'"));
  });

  // Warn: retrospective header present but body empty
  it("warns when retrospective header present but body is empty", async () => {
    const content = [
      "## developer-phoenix-backend Section",
      "",
      "Work done.",
      "",
      "### What I Learned This Step",
      "",
      "",
    ].join("\n");
    writeLog(content);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(
      stderr.includes("subagent-retrospective-guard"),
      "expected warning",
    );
    assert.ok(stderr.includes("empty"));
  });

  // reviewer-static in matcher set
  it("enforces for reviewer-static", async () => {
    const content = [
      "## reviewer-static Section",
      "",
      "Review done.",
      "",
    ].join("\n");
    writeLog(content);
    const stderr = await runHook("reviewer-static");
    assert.ok(stderr.includes("subagent-retrospective-guard"), "expected warning");
  });

  // planner-hugo, planner-vite, planner-html in matcher set
  it("enforces for planner-hugo", async () => {
    const content = [
      "## planner-hugo Section",
      "",
      "Plan here.",
      "",
    ].join("\n");
    writeLog(content);
    const stderr = await runHook("planner-hugo");
    assert.ok(stderr.includes("subagent-retrospective-guard"), "expected warning");
  });

  // Never blocks
  it("never returns block result (observe-only)", async () => {
    const content = [
      "## developer-phoenix-backend Section",
      "",
      "No retrospective here.",
      "",
    ].join("\n");
    writeLog(content);
    process.env["AGENT_TYPE"] = "developer-phoenix-backend";

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../subagent-retrospective-guard");
    mod.register(
      localMockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );

    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (_s: string) => true;
    let result: unknown;
    try {
      result = await capturedHandler!({
        toolName: "session_shutdown",
        toolCallId: "test-id",
        input: {},
      });
    } finally {
      process.stderr.write = origWrite;
    }
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
      "Pi session_shutdown must not block",
    );
  });
});
