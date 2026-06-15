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
    delete process.env["CODEGEN_BUILD_START_TS"];
    delete process.env["AGENT_TYPE"];
  });

  it("passes through when no BUILD_RESULT: in command", async () => {
    const result = await runHook("echo hello");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through when CODEGEN_BUILD_START_TS unset", async () => {
    const result = await runHook('echo "BUILD_RESULT: success"');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through for non-bash tool with BUILD_RESULT:", async () => {
    process.env["CODEGEN_BUILD_START_TS"] = String(
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

      process.env["CODEGEN_BUILD_START_TS"] = buildStartTs;
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
      delete process.env["CODEGEN_BUILD_START_TS"];
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

      process.env["CODEGEN_BUILD_START_TS"] = buildStartTs;
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
      delete process.env["CODEGEN_BUILD_START_TS"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("blocks when OCG repo has uncommitted changes", async () => {
    const tmpProject = fs.mkdtempSync(
      path.join(os.tmpdir(), "build-no-success-ocg-dirty-project-"),
    );
    const tmpOcg = fs.mkdtempSync(
      path.join(os.tmpdir(), "build-no-success-ocg-dirty-ocg-"),
    );
    const originalCwd = process.cwd();
    try {
      // Set up OCG repo first (needed for symlink target)
      execSync("git init -q", { cwd: tmpOcg });
      execSync("git config user.email t@t", { cwd: tmpOcg });
      execSync("git config user.name t", { cwd: tmpOcg });
      execSync("git checkout -q -b main", { cwd: tmpOcg });
      fs.writeFileSync(path.join(tmpOcg, "README"), "ocg-init");
      execSync("git add README", { cwd: tmpOcg });
      execSync("git commit -qm ocg-init", { cwd: tmpOcg });

      // Set up project repo — commit symlink so tree stays clean
      execSync("git init -q", { cwd: tmpProject });
      execSync("git config user.email t@t", { cwd: tmpProject });
      execSync("git config user.name t", { cwd: tmpProject });
      execSync("git checkout -q -b main", { cwd: tmpProject });
      fs.writeFileSync(path.join(tmpProject, "README"), "init");
      fs.mkdirSync(path.join(tmpProject, "codegen/gate-pending"), { recursive: true });
      fs.writeFileSync(
        path.join(tmpProject, "codegen/gate-pending/gate-result.json"),
        JSON.stringify({ verdict: "clear", gate: "make test", mode: "short" }),
      );
      // Commit symlink before generated-code commit
      fs.symlinkSync(tmpOcg, path.join(tmpProject, "codegen/rules"));
      execSync("git add -A", { cwd: tmpProject });
      execSync("git commit -qm init", { cwd: tmpProject });

      const buildStartTs = String(Math.floor(Date.now() / 1000));
      await new Promise((r) => setTimeout(r, 1100));

      fs.writeFileSync(path.join(tmpProject, "README"), "change");
      execSync("git add README", { cwd: tmpProject });
      execSync('git commit -qm "generated code"', { cwd: tmpProject });

      // Make OCG repo dirty AFTER project commits
      fs.writeFileSync(path.join(tmpOcg, "dirty.txt"), "dirty content\n");

      process.env["CODEGEN_BUILD_START_TS"] = buildStartTs;
      process.chdir(tmpProject);

      const result = await runHook('echo "BUILD_RESULT: success"');
      const asObj = result as { block?: boolean; reason?: string } | null;
      assert.ok(
        asObj != null && asObj.block === true,
        `expected block but got: ${JSON.stringify(result)}`,
      );
      assert.ok(
        asObj.reason?.includes("OCG repo has uncommitted changes"),
        `expected OCG dirty message in reason but got: ${asObj.reason}`,
      );
    } finally {
      process.chdir(originalCwd);
      delete process.env["CODEGEN_BUILD_START_TS"];
      fs.rmSync(tmpProject, { recursive: true, force: true });
      fs.rmSync(tmpOcg, { recursive: true, force: true });
    }
  });

  it("passes through when OCG repo is clean", async () => {
    const tmpProject = fs.mkdtempSync(
      path.join(os.tmpdir(), "build-no-success-ocg-clean-project-"),
    );
    const tmpOcg = fs.mkdtempSync(
      path.join(os.tmpdir(), "build-no-success-ocg-clean-ocg-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpOcg });
      execSync("git config user.email t@t", { cwd: tmpOcg });
      execSync("git config user.name t", { cwd: tmpOcg });
      execSync("git checkout -q -b main", { cwd: tmpOcg });
      fs.writeFileSync(path.join(tmpOcg, "README"), "ocg-init");
      execSync("git add README", { cwd: tmpOcg });
      execSync("git commit -qm ocg-init", { cwd: tmpOcg });

      execSync("git init -q", { cwd: tmpProject });
      execSync("git config user.email t@t", { cwd: tmpProject });
      execSync("git config user.name t", { cwd: tmpProject });
      execSync("git checkout -q -b main", { cwd: tmpProject });
      fs.writeFileSync(path.join(tmpProject, "README"), "init");
      fs.mkdirSync(path.join(tmpProject, "codegen/gate-pending"), { recursive: true });
      fs.writeFileSync(
        path.join(tmpProject, "codegen/gate-pending/gate-result.json"),
        JSON.stringify({ verdict: "clear", gate: "make test", mode: "short" }),
      );
      // Commit symlink so tree stays clean
      fs.symlinkSync(tmpOcg, path.join(tmpProject, "codegen/rules"));
      execSync("git add -A", { cwd: tmpProject });
      execSync("git commit -qm init", { cwd: tmpProject });

      const buildStartTs = String(Math.floor(Date.now() / 1000));
      await new Promise((r) => setTimeout(r, 1100));

      fs.writeFileSync(path.join(tmpProject, "README"), "change");
      execSync("git add README", { cwd: tmpProject });
      execSync('git commit -qm "generated code"', { cwd: tmpProject });

      // OCG repo remains clean

      process.env["CODEGEN_BUILD_START_TS"] = buildStartTs;
      process.chdir(tmpProject);

      const result = await runHook('echo "BUILD_RESULT: success"');
      const asObj = result as { block?: boolean } | null;
      assert.ok(
        asObj == null || asObj.block !== true,
        `expected pass-through but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      delete process.env["CODEGEN_BUILD_START_TS"];
      fs.rmSync(tmpProject, { recursive: true, force: true });
      fs.rmSync(tmpOcg, { recursive: true, force: true });
    }
  });

  it("passes through when OCG root equals project root (same repo)", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "build-no-success-ocg-sameroot-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });
      fs.writeFileSync(path.join(tmpDir, "README"), "init");
      fs.mkdirSync(path.join(tmpDir, "codegen/gate-pending"), { recursive: true });
      fs.writeFileSync(
        path.join(tmpDir, "codegen/gate-pending/gate-result.json"),
        JSON.stringify({ verdict: "clear", gate: "make test", mode: "short" }),
      );
      // Symlink inside the same repo; commit it so tree stays clean
      const subdir = path.join(tmpDir, "shared/rules");
      fs.mkdirSync(subdir, { recursive: true });
      fs.writeFileSync(path.join(subdir, ".keep"), "");
      fs.symlinkSync(subdir, path.join(tmpDir, "codegen/rules"));
      execSync("git add -A", { cwd: tmpDir });
      execSync("git commit -qm init", { cwd: tmpDir });

      const buildStartTs = String(Math.floor(Date.now() / 1000));
      await new Promise((r) => setTimeout(r, 1100));

      fs.writeFileSync(path.join(tmpDir, "README"), "change");
      execSync("git add README", { cwd: tmpDir });
      execSync('git commit -qm "generated code"', { cwd: tmpDir });

      process.env["CODEGEN_BUILD_START_TS"] = buildStartTs;
      process.chdir(tmpDir);

      const result = await runHook('echo "BUILD_RESULT: success"');
      const asObj = result as { block?: boolean } | null;
      assert.ok(
        asObj == null || asObj.block !== true,
        `expected pass-through (same repo) but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      delete process.env["CODEGEN_BUILD_START_TS"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("passes through when codegen/rules is not a symlink (fail-open)", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "build-no-success-ocg-nolink-"),
    );
    const originalCwd = process.cwd();
    try {
      execSync("git init -q", { cwd: tmpDir });
      execSync("git config user.email t@t", { cwd: tmpDir });
      execSync("git config user.name t", { cwd: tmpDir });
      execSync("git checkout -q -b main", { cwd: tmpDir });
      fs.writeFileSync(path.join(tmpDir, "README"), "init");
      fs.mkdirSync(path.join(tmpDir, "codegen/gate-pending"), { recursive: true });
      fs.writeFileSync(
        path.join(tmpDir, "codegen/gate-pending/gate-result.json"),
        JSON.stringify({ verdict: "clear", gate: "make test", mode: "short" }),
      );
      // Create codegen/rules as a plain directory (not a symlink) and commit
      fs.mkdirSync(path.join(tmpDir, "codegen/rules"), { recursive: true });
      fs.writeFileSync(path.join(tmpDir, "codegen/rules/.keep"), "");
      execSync("git add -A", { cwd: tmpDir });
      execSync("git commit -qm init", { cwd: tmpDir });

      const buildStartTs = String(Math.floor(Date.now() / 1000));
      await new Promise((r) => setTimeout(r, 1100));

      fs.writeFileSync(path.join(tmpDir, "README"), "change");
      execSync("git add README", { cwd: tmpDir });
      execSync('git commit -qm "generated code"', { cwd: tmpDir });

      process.env["CODEGEN_BUILD_START_TS"] = buildStartTs;
      process.chdir(tmpDir);

      const result = await runHook('echo "BUILD_RESULT: success"');
      const asObj = result as { block?: boolean } | null;
      assert.ok(
        asObj == null || asObj.block !== true,
        `expected pass-through (no symlink) but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      delete process.env["CODEGEN_BUILD_START_TS"];
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

      process.env["CODEGEN_BUILD_START_TS"] = buildStartTs;
      process.chdir(tmpDir);

      const result = await runHook('echo "BUILD_RESULT: success"');
      const asObj = result as { block?: boolean } | null;
      assert.ok(
        asObj == null || asObj.block !== true,
        `expected pass-through but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      delete process.env["CODEGEN_BUILD_START_TS"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
