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
    // getActiveStepLog's resolution step 0 (CODEGEN_LOG_PATH) outranks the
    // tmpDir-scoped .active/mtime scan this suite exercises — an ambient
    // pin from the launching dev/loop session (every role invocation
    // carries one) would silently redirect the hook outside tmpDir.
    delete process.env["CODEGEN_LOG_PATH"];
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
    delete process.env["AGENT_TYPE"];
    delete process.env["CODEGEN_LOG_PATH"];
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
    appendRole("developer-phoenix-backend", "Did the work.");
    appendLearned("developer-phoenix-backend", VALID_LEARNING);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("warns when learning is absent", async () => {
    appendRole("developer-phoenix-backend", "Did the work.");
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
    assert.ok(stderr.includes("codegen-log append developer-phoenix-backend --no-learning"));
  });

  it("warns when no ev:role at all, names codegen-log section", async () => {
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
    assert.ok(
      stderr.includes("codegen-log section developer-phoenix-backend"),
    );
  });

  function appendNoLearning(role: string, text: string): void {
    fs.appendFileSync(
      logPath,
      JSON.stringify({ ev: "no_learning", role, text }) + "\n",
    );
  }

  it("does not warn when ev:no_learning is present (legal empty-turn exit)", async () => {
    appendRole("reviewer-phoenix", "Reviewed the code.");
    appendNoLearning(
      "reviewer-phoenix",
      "refused: handoff named no files, reviewed zero code",
    );
    const stderr = await runHook("reviewer-phoenix");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("does not warn for developer-static with a learned event present", async () => {
    appendRole("developer-static", "Did dev work.");
    appendLearned("developer-static", VALID_LEARNING);
    const stderr = await runHook("developer-static");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("does not warn for developer-static with real content over the bar", async () => {
    appendRole("developer-static", "Did dev work.");
    appendLearned("developer-static", VALID_LEARNING);
    const stderr = await runHook("developer-static");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("warning text never publishes a passing criterion (no char-count wording)", async () => {
    appendRole("developer-phoenix-backend", "Did the work.");
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
    assert.ok(!stderr.includes("40 char"), "must not publish a char-count bar");
    assert.ok(!stderr.includes("forty"), "must not publish 'forty'");
    assert.ok(stderr.includes("no-learning"), "must name the --no-learning escape hatch");
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
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(!stderr.includes("role-retrospective-before-stop"), "expected no warning");
  });

  it("warns when work body is whitespace-only", async () => {
    appendRole("developer-phoenix-backend", "   ");
    appendLearned("developer-phoenix-backend", VALID_LEARNING);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
  });

  it("warns when learning belongs to a different role", async () => {
    appendRole("reviewer-phoenix", "Reviewed the code.");
    appendLearned("developer-phoenix-backend", VALID_LEARNING);
    const stderr = await runHook("reviewer-phoenix");
    assert.ok(stderr.includes("role-retrospective-before-stop"), "expected warning");
  });

  it("never returns block result (observe-only)", async () => {
    process.env["AGENT_TYPE"] = "developer-phoenix-backend";

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
