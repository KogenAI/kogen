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
    // corrupting command parsing. This adds a NEW undocumented literal env
    // var (no .env.sample present in this fixture at all) with samples not
    // staged, so the deny branch IS reachable and exercised here — the dead
    // `/^\+/.test(exDiff)` whole-string guard that used to make this branch
    // unreachable has been removed as part of the literal-arg tightening.
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
        asObj != null && asObj.block === true,
        `expected block (new undocumented literal var, no samples staged) but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("allows argless System.get_env() with no literal arg (no lookup possible)", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "env-var-sample-argless-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });
      fs.writeFileSync(path.join(tmpDir, "foo.exs"), "System.get_env()\n");
      execFileSync("git", ["add", "foo.exs"], { cwd: tmpDir });

      process.chdir(tmpDir);
      const result = await runHook('git commit -m "x"', "committer");
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
        `expected allow (argless read) but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("allows a literal var already declared in .env.sample", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "env-var-sample-documented-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });
      fs.writeFileSync(
        path.join(tmpDir, ".env.sample"),
        "export EXISTING_VAR=\n",
      );
      execFileSync("git", ["add", ".env.sample"], { cwd: tmpDir });
      execSync('git commit -q -m init', { cwd: tmpDir });
      fs.writeFileSync(
        path.join(tmpDir, "foo.exs"),
        'System.get_env("EXISTING_VAR")\n',
      );
      execFileSync("git", ["add", "foo.exs"], { cwd: tmpDir });

      process.chdir(tmpDir);
      const result = await runHook('git commit -m "x"', "committer");
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
        `expected allow (already-documented var) but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("allows when the new undocumented literal var's samples ARE staged", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "env-var-sample-with-samples-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });
      fs.writeFileSync(path.join(tmpDir, "foo.exs"), 'System.get_env("NEW_VAR")\n');
      fs.writeFileSync(path.join(tmpDir, ".env.sample"), "export NEW_VAR=\n");
      fs.writeFileSync(path.join(tmpDir, ".env.prod.sample"), "NEW_VAR=\n");
      execFileSync("git", ["add", "foo.exs", ".env.sample", ".env.prod.sample"], {
        cwd: tmpDir,
      });

      process.chdir(tmpDir);
      const result = await runHook('git commit -m "x"', "committer");
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
        `expected allow (samples staged) but got: ${JSON.stringify(result)}`,
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
