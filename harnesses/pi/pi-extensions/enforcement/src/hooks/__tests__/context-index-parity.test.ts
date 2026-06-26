/**
 * Tests for context-index-parity hook.
 * Mirrors cases from context-index-parity_test.sh.
 * Note: This hook runs git diff --cached requiring a real git repo.
 * Tests cover the behavioral surface accessible without git state.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execSync } from "node:child_process";

function makeCommitEvent(
  command: string,
  agentType: string,
  toolName = "bash",
) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("context-index-parity", { concurrency: 1 }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    command: string,
    agentType = "committer",
    toolName = "bash",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../context-index-parity");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeCommitEvent(command, agentType, toolName));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("git status (non-commit) passes through", async () => {
    const result = await runHook("git status", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("Read tool with git commit payload passes through", async () => {
    const result = await runHook('git commit -m "x"', "committer", "read");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-committer passes through regardless of command", async () => {
    const result = await runHook(
      'git commit -m "x"',
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("echo git commit substring passes through (anchor prevents match)", async () => {
    const result = await runHook('echo "git commit"', "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies when index row references non-existent context file", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "ctx-index-parity-phantom-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git config commit.gpgsign false", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });

      // Initial commit to establish HEAD
      fs.writeFileSync(path.join(tmpDir, "README"), "init");
      execSync("git add README", { cwd: tmpDir });
      execSync("git commit -qm init", { cwd: tmpDir });

      // Stage a context file (so the hook triggers the context-change path)
      fs.mkdirSync(path.join(tmpDir, "context"), { recursive: true });
      fs.writeFileSync(path.join(tmpDir, "context", "existing.md"), "# Existing");
      execSync("git add context/existing.md", { cwd: tmpDir });

      // Stage PROJECT_CONTEXT.md that references a non-existent context file
      const indexBody =
        "# Context\n\nSee context/existing.md and context/phantom.md for details.\n";
      fs.writeFileSync(path.join(tmpDir, "PROJECT_CONTEXT.md"), indexBody);
      execSync("git add PROJECT_CONTEXT.md", { cwd: tmpDir });

      process.chdir(tmpDir);

      const result = await runHook('git commit -m "add context"', "committer");
      const asObj = result as { block?: boolean; reason?: string } | null;
      assert.ok(
        asObj != null && asObj.block === true,
        `expected deny but got: ${JSON.stringify(result)}`,
      );
      assert.ok(
        typeof asObj?.reason === "string" &&
          asObj.reason.includes("context/phantom.md"),
        `reason should mention phantom.md, got: ${asObj?.reason}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("allows when all index rows reference existing context files", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "ctx-index-parity-real-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git config commit.gpgsign false", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });

      // Initial commit
      fs.writeFileSync(path.join(tmpDir, "README"), "init");
      execSync("git add README", { cwd: tmpDir });
      execSync("git commit -qm init", { cwd: tmpDir });

      // Stage a context file
      fs.mkdirSync(path.join(tmpDir, "context"), { recursive: true });
      fs.writeFileSync(path.join(tmpDir, "context", "existing.md"), "# Existing");
      execSync("git add context/existing.md", { cwd: tmpDir });

      // Stage PROJECT_CONTEXT.md that only references the real context file
      const indexBody =
        "# Context\n\nSee context/existing.md for details.\n";
      fs.writeFileSync(path.join(tmpDir, "PROJECT_CONTEXT.md"), indexBody);
      execSync("git add PROJECT_CONTEXT.md", { cwd: tmpDir });

      process.chdir(tmpDir);

      const result = await runHook('git commit -m "add context"', "committer");
      const asObj = result as { block?: boolean } | null;
      assert.ok(
        asObj == null || asObj.block !== true,
        `expected pass-through but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
