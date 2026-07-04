/**
 * Tests for context-file-size-gate hook.
 * Mirrors surface-level cases from context-file-size-gate_test.sh.
 * Note: Deep git-state cases (real staged blobs) are covered by the bash twin.
 * Tests here cover behavioral surface accessible without live git state.
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

describe("context-file-size-gate", () => {
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
    const { register } = await import("../context-file-size-gate");
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

  it("Read tool with git commit payload passes through (tool guard)", async () => {
    const result = await runHook('git commit -m "x"', "committer", "read");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("echo git commit substring passes through (anchor prevents match)", async () => {
    const result = await runHook('echo "git commit"', "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-git-repo passes through (execSync throws, catch returns)", async () => {
    // In a real non-git dir execSync would throw; our catch block handles it.
    // Here the test process IS in a git repo so we just verify passthrough
    // when there are no staged context/*.md files (empty diff output).
    const result = await runHook('git commit -m "x"', "committer");
    // Either passes through (no staged context files in this repo) or throws
    // internally and passes through via catch. Either way: no block.
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks when 'git show' fails unexpectedly for a staged context/*.md file", async () => {
    // Repo-absence was already proven not-the-case (name-status succeeded
    // below); deleting the staged blob's loose object forces 'git show' to
    // throw for a proven-staged path — an anomaly, not repo-absence.
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "context-file-size-gate-show-throw-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });
      fs.mkdirSync(path.join(tmpDir, "context"));
      fs.writeFileSync(
        path.join(tmpDir, "context", "foo.md"),
        "hello world\n",
      );
      execSync("git add context/foo.md", { cwd: tmpDir });

      const lsFiles = execSync("git ls-files -s context/foo.md", {
        cwd: tmpDir,
        encoding: "utf8",
      });
      const hash = lsFiles.split(/\s+/)[1];
      const objPath = path.join(
        tmpDir,
        ".git",
        "objects",
        hash.slice(0, 2),
        hash.slice(2),
      );
      fs.rmSync(objPath);

      process.chdir(tmpDir);
      const result = await runHook('git commit -m "x"', "committer");
      const asObj = result as { block?: boolean; reason?: string } | null;
      assert.ok(
        asObj != null && asObj.block === true,
        `expected block but got: ${JSON.stringify(result)}`,
      );
      assert.ok(
        asObj.reason?.includes("could not read staged blob"),
        `expected "could not read staged blob" in reason but got: ${asObj.reason}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
