/**
 * Tests for stop-verify-planner-gate hook.
 * Mirrors cases from stop-verify-planner-gate_test.sh.
 * Note: Pi session_shutdown is observe-only — warns to stderr, cannot block.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("stop-verify-planner-gate", { concurrency: false }, () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "stop-verify-planner-gate-test-"),
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

  /** Write a cycle log whose planner role event body is the given plan prose. */
  function writeLog(planBody: string): void {
    const line = JSON.stringify({
      ev: "role",
      role: "planner-phoenix",
      body: planBody,
    });
    fs.writeFileSync(
      path.join(
        tmpDir,
        "codegen",
        "logging",
        "20260601_120000_my-step_cycle.jsonl",
      ),
      line + "\n",
    );
  }

  async function runHook(agentType = "planner-phoenix"): Promise<string> {
    process.env["AGENT_TYPE"] = agentType;

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../stop-verify-planner-gate");
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

  // Skip: non-planner agents
  it("skips for non-planner agent", async () => {
    writeLog("## Plan\n\n**Gate**: make test\n");
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(!stderr.includes("stop-verify-planner-gate"), "expected no warning");
  });

  it("skips for committer agent", async () => {
    const stderr = await runHook("committer");
    assert.ok(!stderr.includes("stop-verify-planner-gate"), "expected no warning");
  });

  // Skip: no log found
  it("skips when no step log exists", async () => {
    fs.rmSync(
      path.join(tmpDir, "codegen", "logging"),
      { recursive: true, force: true },
    );
    const stderr = await runHook("planner-phoenix");
    assert.ok(!stderr.includes("stop-verify-planner-gate"), "expected no warning");
  });

  // Valid gate-json block
  it("does not warn when valid gate-json block is present", async () => {
    writeLog([
      "## Plan",
      "",
      "**Gate**:",
      "",
      "```gate-json",
      '{"command": "make test", "mode": "short", "timeout": 0}',
      "```",
      "",
    ].join("\n"));
    const stderr = await runHook("planner-phoenix");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  // Valid prose Gate
  it("does not warn when prose **Gate**: line present", async () => {
    writeLog("## Plan\n\n**Gate**: make test\n");
    const stderr = await runHook("planner-phoenix");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  // Warn: gate missing
  it("warns when **Gate**: is absent", async () => {
    writeLog("## Plan\n\nSome plan without a gate declaration.\n");
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("stop-verify-planner-gate"), "expected warning");
    assert.ok(stderr.includes("missing or placeholder"));
  });

  // Warn: placeholder values
  it("warns when **Gate**: value is TBD", async () => {
    writeLog("## Plan\n\n**Gate**: TBD\n");
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("stop-verify-planner-gate"), "expected warning");
  });

  it("warns when **Gate**: value is pending", async () => {
    writeLog("## Plan\n\n**Gate**: pending\n");
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("stop-verify-planner-gate"), "expected warning");
  });

  it("warns when **Gate**: value is <make target>", async () => {
    writeLog("## Plan\n\n**Gate**: <make target>\n");
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("stop-verify-planner-gate"), "expected warning");
  });

  // Warn: malformed gate-json
  it("warns when gate-json block is malformed JSON", async () => {
    writeLog([
      "## Plan",
      "",
      "**Gate**:",
      "",
      "```gate-json",
      '{"command": "make test"  // missing closing brace',
      "```",
      "",
    ].join("\n"));
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("stop-verify-planner-gate"), "expected warning");
    assert.ok(stderr.includes("malformed"));
  });

  it("warns when gate-json block missing required fields", async () => {
    writeLog([
      "## Plan",
      "",
      "**Gate**:",
      "",
      "```gate-json",
      '{"command": "make test"}',
      "```",
      "",
    ].join("\n"));
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("stop-verify-planner-gate"), "expected warning");
  });

  // Planner variants
  it("enforces for planner-static", async () => {
    writeLog("## Plan\n\nNo gate here.\n");
    const stderr = await runHook("planner-static");
    assert.ok(stderr.includes("stop-verify-planner-gate"), "expected warning");
  });

  // Never blocks
  it("never returns block result (observe-only)", async () => {
    writeLog("## Plan\n\nNo gate.\n");
    process.env["AGENT_TYPE"] = "planner-phoenix";

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../stop-verify-planner-gate");
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
