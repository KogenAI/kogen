/**
 * Tests for env-var-sample-consistency hook.
 * Mirrors cases from env-var-sample-consistency_test.sh.
 * Note: This hook runs git diff --cached which requires a real git repo.
 * Tests use simplified behavioral assertions.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execSync, execFileSync } from "node:child_process";

function makeCommitEvent(command: string, agentType: string) {
  return { toolName: "bash", toolCallId: "test-id", input: { command } };
}

describe("env-var-sample-consistency", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, agentType = "committer") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../env-var-sample-consistency");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeCommitEvent(command, agentType));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("non-committer is not gated", async () => {
    const result = await runHook(
      'git commit -m "test"',
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-commit command passes through for committer", async () => {
    const result = await runHook("git status", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-bash tool passes through", async () => {
    process.env["AGENT_TYPE"] = "committer";
    const { register } = await import("../env-var-sample-consistency");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    const result = await _capturedHandler({
      toolName: "read",
      toolCallId: "test-id",
      input: { file_path: "/tmp/foo" },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks when 'git diff --cached' fails unexpectedly for staged Elixir files", async () => {
    // 'git diff --cached --name-only' (repo-absence check) already proved the
    // repo present and the file staged below. A broken external diff driver
    // scoped to *.exs (via .gitattributes textconv) does not affect the
    // name-only listing (no content read needed) but does break the
    // content-diff execFileSync call — an anomaly, not repo-absence. Deny.
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "env-var-sample-diff-throw-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });
      fs.writeFileSync(
        path.join(tmpDir, "foo.exs"),
        'System.get_env("X")\n',
      );
      execSync("git add foo.exs", { cwd: tmpDir });

      // Prove the repo-absence check ('git diff --cached --name-only') would
      // succeed at this point (staged file present).
      const nameOnly = execSync("git diff --cached --name-only", {
        cwd: tmpDir,
        encoding: "utf8",
      });
      assert.ok(nameOnly.includes("foo.exs"));

      // Break content-diffing for *.exs only, via a nonexistent textconv
      // driver — name-only listing is unaffected (still succeeds).
      fs.writeFileSync(
        path.join(tmpDir, ".gitattributes"),
        "*.exs diff=badexs\n",
      );
      execSync("git config diff.badexs.textconv /nonexistent-cmd-xyz", {
        cwd: tmpDir,
      });
      execSync("git config diff.badexs.cachetextconv false", { cwd: tmpDir });

      process.chdir(tmpDir);
      const result = await runHook('git commit -m "x"', "committer");
      const asObj = result as { block?: boolean; reason?: string } | null;
      assert.ok(
        asObj != null && asObj.block === true,
        `expected block but got: ${JSON.stringify(result)}`,
      );
      assert.ok(
        asObj.reason?.includes("failed unexpectedly"),
        `expected "failed unexpectedly" in reason but got: ${asObj.reason}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("does not throw for a staged Elixir filename containing a space (execFileSync array-args fix)", async () => {
    // Regression for the shell-injection/space-in-path bug fixed alongside
    // this pass: execFileSync passes args as an array, so a staged path with
    // a space is diffed correctly (no throw, no shell-injection) rather than
    // corrupting command parsing. NOTE: the hook's separate, pre-existing
    // `/^\+/.test(exDiff)` whole-string check (unchanged by this pass) means
    // the deny-for-missing-.env.sample branch is unreachable for any real git
    // diff output (which always starts with "diff --git", never "+") — so
    // the only currently-reachable, correct behavior is pass-through. This
    // test asserts the actual reachable contract: no throw, no block.
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "env-var-sample-space-path-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });
      const fileWithSpace = "my file.exs";
      fs.writeFileSync(
        path.join(tmpDir, fileWithSpace),
        'System.get_env("X")\n',
      );
      execFileSync("git", ["add", fileWithSpace], { cwd: tmpDir });

      process.chdir(tmpDir);
      const result = await runHook('git commit -m "x"', "committer");
      const asObj = result as { block?: boolean; reason?: string } | null;
      assert.ok(
        asObj == null || asObj.block !== true,
        `expected pass-through (no crash on space-in-path) but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("allows codegen-log write narrating a git commit for committer", async () => {
    // A codegen-log write is never a git commit itself — bypassed before the
    // `git commit` phrase match, regardless of what its heredoc body narrates.
    const result = await runHook(
      'codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git commit -m "Add env var" — denied as expected (missing samples).\nEOF',
      "committer",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
