/**
 * Tests for pre-commit-guard hook.
 * Mirrors cases from pre-commit-guard_test.sh.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execSync } from "node:child_process";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

function makeRepoWithCommit(commitTs: number): string {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pre-commit-guard-test-"));
  tmpRepos.push(tmpDir);
  execSync("git init -q", { cwd: tmpDir });
  execSync("git config user.email test@example.com", { cwd: tmpDir });
  execSync("git config user.name Test", { cwd: tmpDir });
  fs.writeFileSync(path.join(tmpDir, "baseline.txt"), "baseline\n");
  execSync("git add baseline.txt", { cwd: tmpDir });
  const iso = new Date(commitTs * 1000).toISOString();
  execSync("git -c core.hooksPath=/dev/null commit -q -m baseline", {
    cwd: tmpDir,
    env: {
      ...process.env,
      GIT_AUTHOR_DATE: iso,
      GIT_COMMITTER_DATE: iso,
    },
  });
  return tmpDir;
}

describe("pre-commit-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  const tmpRepos: string[] = [];

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(toolName: string, command: string, agentType = "") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../pre-commit-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent(toolName, command));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["CWD"];
    delete process.env["CODEGEN_BUILD_START_TS"];
  });

  afterEach(() => {
    for (const repo of tmpRepos.splice(0)) {
      fs.rmSync(repo, { recursive: true, force: true });
    }
  });

  it("blocks git commit for developer agent", async () => {
    const result = await runHook(
      "bash",
      "git commit -m 'fix'",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git status for developer agent", async () => {
    const result = await runHook(
      "bash",
      "git status",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git commit for committer", async () => {
    const result = await runHook("bash", "git commit -m 'fix'", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks git rebase for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git rebase -i HEAD~2",
      "developer-phoenix-frontend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git push --force for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git push origin main --force",
      "planner-phoenix",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git reset --hard for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git reset --hard HEAD~1",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git reset for a prior-cycle commit", async () => {
    const repo = makeRepoWithCommit(1700000000);
    process.env["CWD"] = repo;
    process.env["CODEGEN_BUILD_START_TS"] = "1700000100";
    const result = await runHook(
      "bash",
      "git reset HEAD~1",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git reset for this-cycle commit", async () => {
    const repo = makeRepoWithCommit(1700000200);
    process.env["CWD"] = repo;
    process.env["CODEGEN_BUILD_START_TS"] = "1700000100";
    const result = await runHook(
      "bash",
      "git reset HEAD~1",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks for orchestrator (empty agent_type)", async () => {
    const result = await runHook("bash", "git commit -m 'fix'", "");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git add -A for developer agent", async () => {
    const result = await runHook(
      "bash",
      "git add -A",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git add -A for committer", async () => {
    const result = await runHook("bash", "git add -A", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks git stash for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git stash",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git restore foo (no --staged) for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git restore foo",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks git restore --staged foo for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git restore --staged foo",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });
});
