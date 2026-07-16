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
    // getActiveStepLog's resolution step 0 (CODEGEN_LOG_PATH) outranks the
    // .active/mtime scan this suite exercises via tmpDir's fixture files —
    // an ambient pin from the launching dev/loop session (every role
    // invocation carries one) would silently redirect the hook at a log
    // outside tmpDir instead of this test's own writeLog() fixture.
    delete process.env["CODEGEN_LOG_PATH"];
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
    delete process.env["AGENT_TYPE"];
    delete process.env["CODEGEN_LOG_PATH"];
  });

  /** Write a cycle log whose planner role event body is the given plan prose
   * (no plan_gate event) — used for "no structured gate" fixtures. */
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

  /** Write a cycle log with a structured {"ev":"plan_gate",...} event —
   * mirrors what `codegen-log append <role> --plan-gate @-` writes. */
  function writePlanGate(command: string, mode = "short", timeout = 0): void {
    const line = JSON.stringify({
      ev: "plan_gate",
      role: "planner-phoenix",
      command,
      mode,
      timeout,
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
    writePlanGate("make test");
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

  // Valid structured plan_gate event
  it("does not warn when a plan_gate event is present", async () => {
    writePlanGate("make test", "short", 0);
    const stderr = await runHook("planner-phoenix");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  // Warn: gate missing (no plan_gate event; stale prose is never re-parsed)
  it("warns when no plan_gate event exists", async () => {
    writeLog("## Plan\n\nSome plan without a gate declaration.\n");
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("stop-verify-planner-gate"), "expected warning");
    assert.ok(stderr.includes("no plan_gate event"));
  });

  it("warns when a stale **Gate**: prose line exists but no plan_gate event", async () => {
    writeLog("## Plan\n\n**Gate**: make test\n");
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("stop-verify-planner-gate"), "expected warning");
    assert.ok(stderr.includes("no plan_gate event"));
  });

  // Warn: placeholder values
  it("warns when plan_gate command is TBD", async () => {
    writePlanGate("TBD");
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("stop-verify-planner-gate"), "expected warning");
  });

  it("warns when plan_gate command is pending", async () => {
    writePlanGate("pending");
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("stop-verify-planner-gate"), "expected warning");
  });

  it("warns when plan_gate command is <make target>", async () => {
    writePlanGate("<make target>");
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
