/**
 * Tests for subagent-retrospective-guard hook.
 * Mirrors cases from subagent-retrospective-guard_test.sh (JSONL cycle log storage).
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

  /** Write a cycle log from a list of raw JSONL event lines (already JSON-encoded). */
  function writeLogLines(lines: string[]): void {
    fs.writeFileSync(
      path.join(
        tmpDir,
        "codegen",
        "logging",
        "20260601_120000_test_cycle.jsonl",
      ),
      lines.join("\n") + "\n",
    );
  }

  function roleEvent(role: string, body: string): string {
    return JSON.stringify({ ev: "role", role, body });
  }

  function learnedEvent(role: string, text: string): string {
    return JSON.stringify({ ev: "learned", role, text });
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
    writeLogLines([roleEvent("committer", "Done.")]);
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

  // Skip: no role event for this agent (defensive)
  it("skips when agent has no role event in the log", async () => {
    writeLogLines([roleEvent("some-other", "Content.")]);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(!stderr.includes("subagent-retrospective-guard"), "expected no warning");
  });

  // Valid: retrospective present with content
  it("does not warn when developer-phoenix-backend has retrospective with bullet", async () => {
    writeLogLines([
      roleEvent(
        "developer-phoenix-backend",
        "Work done.\n\n### What I Learned This Step\n\n- nothing notable",
      ),
    ]);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("does not warn for developer-phoenix-frontend with retrospective", async () => {
    writeLogLines([
      roleEvent(
        "developer-phoenix-frontend",
        "Work done.\n\n### What I Learned This Step\n\n- [local] something specific",
      ),
    ]);
    const stderr = await runHook("developer-phoenix-frontend");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("does not warn for reviewer-phoenix with retrospective", async () => {
    writeLogLines([
      roleEvent(
        "reviewer-phoenix",
        "Review done.\n\n### What I Learned This Step\n\n- nothing notable",
      ),
    ]);
    const stderr = await runHook("reviewer-phoenix");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  // Valid: planner-phoenix matches any role startsWith "planner"
  it("does not warn for planner-phoenix with retrospective in its role body", async () => {
    writeLogLines([
      roleEvent(
        "planner-phoenix",
        "Plan content here.\n\n### What I Learned This Step\n\n- [local] planner finding",
      ),
      roleEvent("developer-phoenix-backend", "stub"),
    ]);
    const stderr = await runHook("planner-phoenix");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  // Warn: retrospective header missing
  it("warns when developer-phoenix-backend body lacks retrospective header", async () => {
    writeLogLines([
      roleEvent("developer-phoenix-backend", "Work done.\n\n**Result**: complete."),
    ]);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(
      stderr.includes("subagent-retrospective-guard"),
      "expected warning",
    );
    assert.ok(stderr.includes("missing the '### What I Learned This Step'"));
  });

  // Warn: retrospective header present but body empty
  it("warns when retrospective header present but body is empty", async () => {
    writeLogLines([
      roleEvent(
        "developer-phoenix-backend",
        "Work done.\n\n### What I Learned This Step\n\n",
      ),
    ]);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(
      stderr.includes("subagent-retrospective-guard"),
      "expected warning",
    );
    assert.ok(stderr.includes("empty"));
  });

  // reviewer-static in matcher set
  it("enforces for reviewer-static", async () => {
    writeLogLines([roleEvent("reviewer-static", "Review done.")]);
    const stderr = await runHook("reviewer-static");
    assert.ok(stderr.includes("subagent-retrospective-guard"), "expected warning");
  });

  // planner-static in matcher set
  it("does not warn for planner-static with retrospective in its role body", async () => {
    writeLogLines([
      roleEvent(
        "planner-static",
        "Plan content here.\n\n### What I Learned This Step\n\n- [local] static planner finding",
      ),
    ]);
    const stderr = await runHook("planner-static");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("warns for planner-static missing retrospective", async () => {
    writeLogLines([
      roleEvent("planner-static", "Plan content here, no retrospective."),
    ]);
    const stderr = await runHook("planner-static");
    assert.ok(stderr.includes("subagent-retrospective-guard"), "expected warning");
  });

  // Re-spawn: multiple role events for the same agent — bodies are
  // CONCATENATED (not last-wins) under the JSONL contract, so the retro
  // header anywhere across all passes satisfies the check.
  it("does not warn when second pass's role event has retrospective (first pass missing)", async () => {
    writeLogLines([
      roleEvent("reviewer-phoenix", "**Result**: no retrospective in pass 1."),
      roleEvent(
        "reviewer-phoenix",
        "**Result**: Done.\n\n### What I Learned This Step\n\n- nothing notable",
      ),
    ]);
    const stderr = await runHook("reviewer-phoenix");
    assert.ok(!stderr.includes("WARNING"), "expected no warning — concatenated body has retro");
  });

  it("does not warn when first pass had retro even if second pass omits it (concatenation, not last-wins)", async () => {
    writeLogLines([
      roleEvent(
        "reviewer-phoenix",
        "**Result**: Done.\n\n### What I Learned This Step\n\n- nothing notable",
      ),
      roleEvent("reviewer-phoenix", "**Result**: Done again, forgot retro."),
    ]);
    const stderr = await runHook("reviewer-phoenix");
    // Concatenation means the retro header from pass 1 is still present in
    // the joined body — this is a deliberate semantic change from the old
    // last-block-wins markdown parse (see planner's collapse note).
    assert.ok(!stderr.includes("WARNING"), "expected no warning — concatenated body still has retro");
  });

  // Dedicated learned event satisfies the check even with no retro header in body.
  it("does not warn when a dedicated learned event is present", async () => {
    writeLogLines([
      roleEvent("developer-phoenix-backend", "Work done, no retro block here."),
      learnedEvent("developer-phoenix-backend", "[local] captured via --learned"),
    ]);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(!stderr.includes("WARNING"), "expected no warning — dedicated learned event present");
  });

  it("warns when a dedicated learned event is present but blank", async () => {
    writeLogLines([
      roleEvent("developer-phoenix-backend", "Work done, no retro block here."),
      learnedEvent("developer-phoenix-backend", "   "),
    ]);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(stderr.includes("subagent-retrospective-guard"), "expected warning — blank learned event does not count");
  });

  // Malformed line in cycle log is skipped, not fatal.
  it("skips malformed JSONL lines without crashing", async () => {
    writeLogLines([
      "not-json-at-all",
      roleEvent(
        "developer-phoenix-backend",
        "Work done.\n\n### What I Learned This Step\n\n- nothing notable",
      ),
    ]);
    const stderr = await runHook("developer-phoenix-backend");
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  // Never blocks
  it("never returns block result (observe-only)", async () => {
    writeLogLines([
      roleEvent("developer-phoenix-backend", "No retrospective here."),
    ]);
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
