/**
 * Tests for committer-gate-verdict-clear hook.
 * Mirrors cases from committer-gate-verdict-clear_test.sh.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

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
});
