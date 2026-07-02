/**
 * Tests for stop-gate-failure-breaker hook.
 *
 * Pi session_shutdown is observe-only — this hook MEASURES (count FAILED ❌)
 * and SURFACES (stderr + step-log marker) at threshold ≥3 with a 2-surface cap.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

function counterPath(sessionId: string): string {
  return path.join(os.tmpdir(), `pi-gate-breaker-${sessionId}.count`);
}

describe("stop-gate-failure-breaker", () => {
  let _capturedHandler: () => Promise<void>;
  const mockPi = {
    on: (_event: string, handler: () => Promise<void>) => {
      _capturedHandler = handler;
    },
  };

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["SESSION_ID"];
    delete process.env["CWD"];
  });

  /**
   * Sets up a temp dir with a step log containing the given content
   * and an optional gate-result.json.
   */
  function setup(opts: {
    logContent: string;
    verdict?: string;
    sessionId: string;
  }): { tmpDir: string; logPath: string } {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "sgfb-"));
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    const logPath = path.join(loggingDir, "20260101_000000_step1_test.md");
    fs.writeFileSync(logPath, opts.logContent);

    if (opts.verdict !== undefined) {
      const gateDir = path.join(tmpDir, "codegen", "gate-pending");
      fs.mkdirSync(gateDir, { recursive: true });
      fs.writeFileSync(
        path.join(gateDir, "gate-result.json"),
        JSON.stringify({ verdict: opts.verdict }),
      );
    }
    return { tmpDir, logPath };
  }

  async function runHook(
    agentType: string,
    tmpDir: string,
    sessionId: string,
  ): Promise<{ stderrMessages: string[] }> {
    process.env["AGENT_TYPE"] = agentType;
    process.env["SESSION_ID"] = sessionId;
    process.env["CWD"] = tmpDir;

    const stderrMessages: string[] = [];
    const origStderrWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (msg: string | Uint8Array) => {
      stderrMessages.push(typeof msg === "string" ? msg : msg.toString());
      return true;
    };

    try {
      const { register } = await import("../stop-gate-failure-breaker");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      await _capturedHandler();
    } finally {
      process.stderr.write = origStderrWrite;
      delete process.env["AGENT_TYPE"];
      delete process.env["SESSION_ID"];
      delete process.env["CWD"];
    }
    return { stderrMessages };
  }

  it("non-developer agent is a no-op (no stderr, no log append)", async () => {
    const sid = `sgfb1-${Date.now()}`;
    const { tmpDir, logPath } = setup({
      logContent: "FAILED ❌\nFAILED ❌\nFAILED ❌\n",
      verdict: "failed",
      sessionId: sid,
    });
    try {
      const { stderrMessages } = await runHook("reviewer-phoenix", tmpDir, sid);
      assert.strictEqual(stderrMessages.length, 0, "expected no stderr for non-developer");
      const content = fs.readFileSync(logPath, "utf8");
      assert.ok(
        !content.includes("stop-gate-failure-breaker Section"),
        "expected no log marker for non-developer",
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("failedCount < 3 produces no surface even with verdict=failed", async () => {
    const sid = `sgfb2-${Date.now()}`;
    const { tmpDir, logPath } = setup({
      logContent: "FAILED ❌\nFAILED ❌\n",
      verdict: "failed",
      sessionId: sid,
    });
    try {
      const { stderrMessages } = await runHook("developer-phoenix-backend", tmpDir, sid);
      const escalation = stderrMessages.filter((m) =>
        m.includes("stop-gate-failure-breaker"),
      );
      assert.strictEqual(escalation.length, 0, "expected no escalation below threshold");
      const content = fs.readFileSync(logPath, "utf8");
      assert.ok(
        !content.includes("stop-gate-failure-breaker Section"),
        "expected no log marker below threshold",
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("failedCount ≥ 3 AND verdict=failed → stderr escalation + step-log marker + counter=1", async () => {
    const sid = `sgfb3-${Date.now()}`;
    const { tmpDir, logPath } = setup({
      logContent: "FAILED ❌\nFAILED ❌\nFAILED ❌\n",
      verdict: "failed",
      sessionId: sid,
    });
    try {
      const { stderrMessages } = await runHook("developer-phoenix-backend", tmpDir, sid);
      const escalation = stderrMessages.filter((m) =>
        m.includes("stop-gate-failure-breaker"),
      );
      assert.ok(escalation.length > 0, "expected escalation message on stderr");
      assert.ok(
        escalation[0].includes("Escalate to planner-phoenix"),
        `expected planner-escalation message, got: ${escalation[0]}`,
      );
      const content = fs.readFileSync(logPath, "utf8");
      assert.ok(
        content.includes("stop-gate-failure-breaker Section"),
        "expected step-log marker appended",
      );
      // Counter should record surface count = 1.
      const counter = fs.readFileSync(counterPath(sid), "utf8");
      assert.ok(counter.includes("1"), "expected counter=1 after first surface");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("verdict ≠ failed (inconclusive) with failedCount ≥ 3 → no surface", async () => {
    const sid = `sgfb4-${Date.now()}`;
    const { tmpDir, logPath } = setup({
      logContent: "FAILED ❌\nFAILED ❌\nFAILED ❌\n",
      verdict: "inconclusive",
      sessionId: sid,
    });
    try {
      const { stderrMessages } = await runHook("developer-phoenix-frontend", tmpDir, sid);
      const escalation = stderrMessages.filter((m) =>
        m.includes("stop-gate-failure-breaker"),
      );
      assert.strictEqual(escalation.length, 0, "expected no escalation when verdict≠failed");
      const content = fs.readFileSync(logPath, "utf8");
      assert.ok(
        !content.includes("stop-gate-failure-breaker Section"),
        "expected no log marker when verdict≠failed",
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("surfaceCount already at cap (2) → counter cleared, no further surface", async () => {
    const sid = `sgfb5-${Date.now()}`;
    const { tmpDir, logPath } = setup({
      logContent: "FAILED ❌\nFAILED ❌\nFAILED ❌\n",
      verdict: "failed",
      sessionId: sid,
    });
    // Pre-seed counter at cap=2 for this log.
    const logFiles = fs.readdirSync(path.join(tmpDir, "codegen", "logging"));
    const activeLog = path.join(tmpDir, "codegen", "logging", logFiles[0]);
    fs.writeFileSync(counterPath(sid), `${activeLog}\n2\n`);
    try {
      const { stderrMessages } = await runHook("developer-phoenix-backend", tmpDir, sid);
      const escalation = stderrMessages.filter((m) =>
        m.includes("stop-gate-failure-breaker") && m.includes("BLOCKED"),
      );
      assert.strictEqual(escalation.length, 0, "expected no escalation at cap");
      // Counter file should be cleared after cap.
      assert.ok(
        !fs.existsSync(counterPath(sid)),
        "expected counter file removed after cap",
      );
      const content = fs.readFileSync(logPath, "utf8");
      assert.ok(
        !content.includes("stop-gate-failure-breaker Section"),
        "expected no log marker at cap",
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("forward progress (new step log basename) resets surface counter", async () => {
    const sid = `sgfb6-${Date.now()}`;
    const { tmpDir, logPath } = setup({
      logContent: "FAILED ❌\nFAILED ❌\nFAILED ❌\n",
      verdict: "failed",
      sessionId: sid,
    });
    // Pre-seed counter pointing at a DIFFERENT (old) step log, count=2.
    fs.writeFileSync(counterPath(sid), `/tmp/old-step-log.md\n2\n`);
    try {
      const { stderrMessages } = await runHook("developer-static", tmpDir, sid);
      // Counter was for old step — new step resets it, threshold met → surface now.
      const escalation = stderrMessages.filter((m) =>
        m.includes("stop-gate-failure-breaker"),
      );
      assert.ok(
        escalation.length > 0,
        "expected escalation after forward-progress reset",
      );
      const content = fs.readFileSync(logPath, "utf8");
      assert.ok(
        content.includes("stop-gate-failure-breaker Section"),
        "expected step-log marker after forward-progress reset",
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      fs.rmSync(counterPath(sid), { force: true });
    }
  });
});
