/**
 * Tests for role-retrospective-before-stop hook.
 * Mirrors cases from role-retrospective-before-stop_test.sh.
 * Note: Pi session_shutdown is observe-only — warns to stderr, cannot block.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const VALID_LEARNING =
  "This is a genuinely useful retrospective sentence describing what was learned.";

describe("role-retrospective-before-stop", { concurrency: false }, () => {
  let tmpDir: string;
  let logPath: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "role-retrospective-before-stop-test-"),
    );
    fs.mkdirSync(path.join(tmpDir, "codegen", "logging"), { recursive: true });
    logPath = path.join(
      tmpDir,
      "codegen",
      "logging",
      "20260714_120000_my-step_cycle.jsonl",
    );
    fs.writeFileSync(logPath, "");
    process.env["CWD"] = tmpDir;
    delete process.env["AGENT_TYPE"];
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
    delete process.env["AGENT_TYPE"];
  });

  function appendRole(role: string, body: string): void {
    fs.appendFileSync(logPath, JSON.stringify({ ev: "role", role, body }) + "\n");
  }

  function appendLearned(role: string, text: string): void {
    fs.appendFileSync(
      logPath,
      JSON.stringify({ ev: "learned", role, text }) + "\n",
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

    const mod = await import("../role-retrospective-before-stop");
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

  it("does not warn when work + learning are present", async () => {
    appendRole("planner-phoenix", "Did the planning work.");
    appendLearned("planner-phoenix", VALID_LEARNING);
    const stderr = await runHook("planner-phoenix");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("warns when learning is absent", async () => {
    appendRole("planner-phoenix", "Did the planning work.");
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
    assert.ok(stderr.includes("codegen-log append planner-phoenix --learned"));
  });

  it("warns when no ev:role at all, names codegen-log section", async () => {
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
    assert.ok(
      stderr.includes("codegen-log section developer-phoenix-backend"),
    );
  });

  it("warns when learning is a placeholder ('nothing notable')", async () => {
    appendRole("reviewer-phoenix", "Reviewed the code.");
    appendLearned("reviewer-phoenix", "nothing notable");
    const stderr = await runHook("reviewer-phoenix");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
  });

  it("warns when learning is a placeholder ('none')", async () => {
    appendRole("reviewer-static", "Reviewed the code.");
    appendLearned("reviewer-static", "none");
    const stderr = await runHook("reviewer-static");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
  });

  it("warns when learning is under the 40-char bar", async () => {
    appendRole("developer-static", "Did dev work.");
    appendLearned("developer-static", "short but real text");
    const stderr = await runHook("developer-static");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
  });

  it("does not warn for developer-static with real content over the bar", async () => {
    appendRole("developer-static", "Did dev work.");
    appendLearned("developer-static", VALID_LEARNING);
    const stderr = await runHook("developer-static");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("skips for context-curator (exempt)", async () => {
    const stderr = await runHook("context-curator");
    assert.ok(!stderr.includes("role-retrospective-before-stop"), "expected no warning");
  });

  it("skips for committer (exempt)", async () => {
    const stderr = await runHook("committer");
    assert.ok(!stderr.includes("role-retrospective-before-stop"), "expected no warning");
  });

  it("skips when AGENT_TYPE is empty (fail-open)", async () => {
    const stderr = await runHook("");
    assert.ok(!stderr.includes("role-retrospective-before-stop"), "expected no warning");
  });

  it("skips when no cycle log exists (fail-open)", async () => {
    fs.rmSync(path.join(tmpDir, "codegen", "logging"), {
      recursive: true,
      force: true,
    });
    const stderr = await runHook("planner-phoenix");
    assert.ok(!stderr.includes("role-retrospective-before-stop"), "expected no warning");
  });

  it("warns when work body is whitespace-only", async () => {
    appendRole("planner-phoenix", "   ");
    appendLearned("planner-phoenix", VALID_LEARNING);
    const stderr = await runHook("planner-phoenix");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
  });

  it("warns when learning belongs to a different role", async () => {
    appendRole("reviewer-phoenix", "Reviewed the code.");
    appendLearned("developer-phoenix-backend", VALID_LEARNING);
    const stderr = await runHook("reviewer-phoenix");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
  });

  it("never returns block result (observe-only)", async () => {
    process.env["AGENT_TYPE"] = "planner-phoenix";

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../role-retrospective-before-stop");
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
