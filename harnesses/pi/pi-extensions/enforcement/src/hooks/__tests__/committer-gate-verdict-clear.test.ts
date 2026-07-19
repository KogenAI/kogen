/**
 * Tests for committer-gate-verdict-clear hook.
 * Mirrors cases from committer-gate-verdict-clear_test.sh.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { execFileSync } from "node:child_process";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

function writeGateResult(dir: string, body: string): void {
  const gp = path.join(dir, "codegen", "gate-pending");
  fs.mkdirSync(gp, { recursive: true });
  fs.writeFileSync(path.join(gp, "gate-result.json"), body);
}

describe("committer-gate-verdict-clear", { concurrency: 1 }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  let savedEnv: Record<string, string | undefined>;
  let tmpDir: string;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    command: string,
    agentType = "committer",
    extraEnv: Record<string, string> = {},
  ) {
    process.env["AGENT_TYPE"] = agentType;
    for (const [k, v] of Object.entries(extraEnv)) {
      process.env[k] = v;
    }
    const { register } = await import("../committer-gate-verdict-clear");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent("bash", command));
  }

  beforeEach(() => {
    savedEnv = {
      AGENT_TYPE: process.env["AGENT_TYPE"],
      CLAUDE_PROJECT_DIR: process.env["CLAUDE_PROJECT_DIR"],
    };
    delete process.env["AGENT_TYPE"];
    delete process.env["CLAUDE_PROJECT_DIR"];
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-gate-verdict-test-"));
  });

  afterEach(() => {
    for (const [k, v] of Object.entries(savedEnv)) {
      if (v === undefined) {
        delete process.env[k];
      } else {
        process.env[k] = v;
      }
    }
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it("passes through for non-committer agent", async () => {
    const result = await runHook(
      "git commit -m test",
      "developer-phoenix-backend",
      { CLAUDE_PROJECT_DIR: tmpDir },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows when command is not git commit", async () => {
    const result = await runHook("git status", "committer", {
      CLAUDE_PROJECT_DIR: tmpDir,
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows codegen-log write narrating git commit", async () => {
    const result = await runHook(
      'codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git commit -m "msg" successfully.\nEOF',
      "committer",
      { CLAUDE_PROJECT_DIR: tmpDir },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git commit-graph (word-boundary fix: no substring match)", async () => {
    const result = await runHook("git commit-graph write", "committer", {
      CLAUDE_PROJECT_DIR: tmpDir,
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Test 4b (this pitch): crossed cell — the codegen-log token spelled
  // inside a REAL commit message (not routed through codegen-log; command
  // word is git). With a failed verdict, the verdict check still applies —
  // MUST DENY.
  it("denies with codegen-log token spelled in real commit message, verdict=failed (crossed cell)", async () => {
    writeGateResult(tmpDir, JSON.stringify({ verdict: "failed" }));
    const result = await runHook(
      "git commit -m 'ran codegen-log section developer'",
      "committer",
      { CLAUDE_PROJECT_DIR: tmpDir },
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("denies when gate-result.json is absent", async () => {
    const result = await runHook("git commit -m test", "committer", {
      CLAUDE_PROJECT_DIR: tmpDir,
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows when verdict=clear", async () => {
    writeGateResult(tmpDir, JSON.stringify({ verdict: "clear" }));
    const result = await runHook("git commit -m test", "committer", {
      CLAUDE_PROJECT_DIR: tmpDir,
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies when verdict=failed", async () => {
    writeGateResult(tmpDir, JSON.stringify({ verdict: "failed" }));
    const result = await runHook("git commit -m test", "committer", {
      CLAUDE_PROJECT_DIR: tmpDir,
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("denies when verdict=inconclusive", async () => {
    writeGateResult(tmpDir, JSON.stringify({ verdict: "inconclusive" }));
    const result = await runHook("git commit -m test", "committer", {
      CLAUDE_PROJECT_DIR: tmpDir,
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("denies when gate-result.json is malformed JSON", async () => {
    writeGateResult(tmpDir, "{not valid json");
    const result = await runHook("git commit -m test", "committer", {
      CLAUDE_PROJECT_DIR: tmpDir,
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows --amend when verdict=clear", async () => {
    writeGateResult(tmpDir, JSON.stringify({ verdict: "clear" }));
    const result = await runHook("git commit --amend -m test", "committer", {
      CLAUDE_PROJECT_DIR: tmpDir,
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies --amend when verdict=failed", async () => {
    writeGateResult(tmpDir, JSON.stringify({ verdict: "failed" }));
    const result = await runHook("git commit --amend -m test", "committer", {
      CLAUDE_PROJECT_DIR: tmpDir,
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows when payload cwd is a subdir of a git repo with clear gate-result at the root", async () => {
    execFileSync("git", ["init", "-q"], { cwd: tmpDir });
    writeGateResult(tmpDir, JSON.stringify({ verdict: "clear" }));
    const subDir = path.join(tmpDir, "sub", "dir");
    fs.mkdirSync(subDir, { recursive: true });
    const result = await runHook("git commit -m test", "committer", {
      CLAUDE_PROJECT_DIR: subDir,
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies with a message naming both resolved and raw dirs outside any repo", async () => {
    const result = await runHook("git commit -m test", "committer", {
      CLAUDE_PROJECT_DIR: tmpDir,
    });
    assert.ok((result as { block?: boolean }).block === true);
    const reason = (result as { reason?: string }).reason ?? "";
    assert.ok(
      reason.includes(`is missing at ${tmpDir} (resolved from ${tmpDir})`),
      `reason did not name resolved+raw dirs: ${reason}`,
    );
  });

  it("denies naming the anchored repo root when gate-result is genuinely absent", async () => {
    execFileSync("git", ["init", "-q"], { cwd: tmpDir });
    const subDir = path.join(tmpDir, "sub");
    fs.mkdirSync(subDir, { recursive: true });
    const result = await runHook("git commit -m test", "committer", {
      CLAUDE_PROJECT_DIR: subDir,
    });
    assert.ok((result as { block?: boolean }).block === true);
    const reason = (result as { reason?: string }).reason ?? "";
    assert.ok(
      reason.includes(`is missing at ${tmpDir} (resolved from ${subDir})`),
      `reason did not name anchored repo root: ${reason}`,
    );
  });
});
