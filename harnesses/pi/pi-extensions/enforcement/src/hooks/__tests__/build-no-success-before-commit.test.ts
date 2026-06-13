/**
 * Tests for build-no-success-before-commit hook.
 * Mirrors cases from build-no-success-before-commit_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execSync } from "node:child_process";

function makeBashEvent(command: string) {
  return { toolName: "bash", toolCallId: "test-id", input: { command } };
}

describe("build-no-success-before-commit", { concurrency: 1 }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, toolName = "bash") {
    const { register } = await import("../build-no-success-before-commit");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName,
      toolCallId: "test-id",
      input: { command },
    });
  }

  beforeEach(() => {
    delete process.env["COMBOBULATE_BUILD_START_TS"];
    delete process.env["AGENT_TYPE"];
  });

  it("passes through when no BUILD_RESULT: in command", async () => {
    const result = await runHook("echo hello");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through when COMBOBULATE_BUILD_START_TS unset", async () => {
    const result = await runHook('echo "BUILD_RESULT: success"');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through for non-bash tool with BUILD_RESULT:", async () => {
    process.env["COMBOBULATE_BUILD_START_TS"] = String(
      Math.floor(Date.now() / 1000),
    );
    const result = await runHook("BUILD_RESULT: foo", "read");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks when tree is dirty after commit", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "build-no-success-dirty-"),
    );
    const originalCwd = process.cwd();
    try {
      // Set up a real git repo with an initial commit
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });
      fs.writeFileSync(path.join(tmpDir, "README"), "init");
      // Write gate-result.json with clear verdict so verdict check passes,
      // allowing the dirty-tree check to be the blocking gate.
      fs.mkdirSync(path.join(tmpDir, "codegen/gate-pending"), {
        recursive: true,
      });
      fs.writeFileSync(
        path.join(tmpDir, "codegen/gate-pending/gate-result.json"),
        JSON.stringify({ verdict: "clear", gate: "make test", mode: "short" }),
      );
      execSync("git add -A", { cwd: tmpDir });
      execSync("git commit -qm init", { cwd: tmpDir });

      // Record build start BEFORE the next commit
      const buildStartTs = String(Math.floor(Date.now() / 1000));
      // Small delay so commit ts > buildStartTs
      await new Promise((r) => setTimeout(r, 1100));

      // Make a commit after build start
      fs.writeFileSync(path.join(tmpDir, "README"), "change");
      execSync("git add README", { cwd: tmpDir });
      execSync('git commit -qm "generated code"', { cwd: tmpDir });

      // Create a dirty (uncommitted) file
      fs.writeFileSync(path.join(tmpDir, "dirty.txt"), "dirty content\n");

      process.env["COMBOBULATE_BUILD_START_TS"] = buildStartTs;
      process.chdir(tmpDir);

      const result = await runHook('echo "BUILD_RESULT: success"');
      const asObj = result as { block?: boolean; reason?: string } | null;
      assert.ok(
        asObj != null && asObj.block === true,
        `expected block but got: ${JSON.stringify(result)}`,
      );
      assert.ok(
        asObj.reason?.includes("working tree not clean"),
        `expected "working tree not clean" in reason but got: ${asObj.reason}`,
      );
    } finally {
      process.chdir(originalCwd);
      delete process.env["COMBOBULATE_BUILD_START_TS"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("blocks when gate-result verdict is not clear (inconclusive)", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "build-no-success-verdict-"),
    );
    const originalCwd = process.cwd();
    try {
      // Set up a real git repo with a post-build-start commit and clean tree
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });
      fs.writeFileSync(path.join(tmpDir, "README"), "init");
      execSync("git add README", { cwd: tmpDir });
      execSync("git commit -qm init", { cwd: tmpDir });

      const buildStartTs = String(Math.floor(Date.now() / 1000));
      await new Promise((r) => setTimeout(r, 1100));

      fs.writeFileSync(path.join(tmpDir, "README"), "change");
      execSync("git add README", { cwd: tmpDir });
      execSync('git commit -qm "generated code"', { cwd: tmpDir });

      // Write gate-result.json with inconclusive verdict
      fs.mkdirSync(path.join(tmpDir, "codegen/gate-pending"), {
        recursive: true,
      });
      fs.writeFileSync(
        path.join(tmpDir, "codegen/gate-pending/gate-result.json"),
        JSON.stringify({ verdict: "inconclusive", gate: "make test", mode: "short" }),
      );

      process.env["COMBOBULATE_BUILD_START_TS"] = buildStartTs;
      process.chdir(tmpDir);

      const result = await runHook('echo "BUILD_RESULT: success"');
      const asObj = result as { block?: boolean; reason?: string } | null;
      assert.ok(
        asObj != null && asObj.block === true,
        `expected block but got: ${JSON.stringify(result)}`,
      );
      assert.ok(
        asObj.reason?.includes("verdict=clear"),
        `expected "verdict=clear" in reason but got: ${asObj.reason}`,
      );
    } finally {
      process.chdir(originalCwd);
      delete process.env["COMBOBULATE_BUILD_START_TS"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("passes through when gate-result verdict is clear and tree is clean", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "build-no-success-clear-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });
      fs.writeFileSync(path.join(tmpDir, "README"), "init");
      execSync("git add README", { cwd: tmpDir });
      execSync("git commit -qm init", { cwd: tmpDir });

      const buildStartTs = String(Math.floor(Date.now() / 1000));
      await new Promise((r) => setTimeout(r, 1100));

      fs.writeFileSync(path.join(tmpDir, "README"), "change");
      // Write gate-result.json with clear verdict and commit together to keep tree clean
      fs.mkdirSync(path.join(tmpDir, "codegen/gate-pending"), {
        recursive: true,
      });
      fs.writeFileSync(
        path.join(tmpDir, "codegen/gate-pending/gate-result.json"),
        JSON.stringify({ verdict: "clear", gate: "make test", mode: "short" }),
      );
      execSync("git add -A", { cwd: tmpDir });
      execSync('git commit -qm "generated code"', { cwd: tmpDir });

      process.env["COMBOBULATE_BUILD_START_TS"] = buildStartTs;
      process.chdir(tmpDir);

      const result = await runHook('echo "BUILD_RESULT: success"');
      const asObj = result as { block?: boolean } | null;
      assert.ok(
        asObj == null || asObj.block !== true,
        `expected pass-through but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      delete process.env["COMBOBULATE_BUILD_START_TS"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
