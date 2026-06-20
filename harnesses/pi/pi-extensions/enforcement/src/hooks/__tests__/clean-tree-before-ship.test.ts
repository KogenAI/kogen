/**
 * Tests for clean-tree-before-ship hook.
 * Mirrors cases from clean-tree-before-ship_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execSync } from "node:child_process";

describe("clean-tree-before-ship", { concurrency: 1 }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, toolName = "bash") {
    const { register } = await import("../clean-tree-before-ship");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName,
      toolCallId: "test-id",
      input: { command },
    });
  }

  // Case 1: no-match command → pass-through
  it("passes through when command does not contain both literals", async () => {
    const result = await runHook("echo hello");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Case 2: ship mv + clean tree → pass-through
  it("passes through when ship mv on clean tree", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "clean-tree-ship-clean-"),
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

      process.chdir(tmpDir);

      const result = await runHook(
        "mv codegen/pitches/ready/my-slug.md codegen/pitches/shipped/my-slug.md",
      );
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

  // Case 3: ship mv + dirty tree → block
  it("blocks when ship mv on dirty tree", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "clean-tree-ship-dirty-"),
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

      // Create a dirty (untracked) file
      fs.writeFileSync(path.join(tmpDir, "dirty.txt"), "dirty content\n");

      process.chdir(tmpDir);

      const result = await runHook(
        "mv codegen/pitches/ready/my-slug.md codegen/pitches/shipped/my-slug.md",
      );
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
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  // Case 4: non-bash tool → pass-through
  it("passes through for non-bash tool", async () => {
    const result = await runHook(
      "mv codegen/pitches/ready/x.md codegen/pitches/shipped/x.md",
      "read",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Case 5: promotion mv (ready-only, no shipped/) → pass-through
  it("passes through for promotion mv (draft→ready, no shipped/ present)", async () => {
    const result = await runHook(
      "mv codegen/pitches/draft/x.md codegen/pitches/ready/x.md",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Case 6: not a git repo → pass-through (fail-open)
  it("passes through when cwd is not a git repo (fail-open)", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "clean-tree-ship-nongit-"),
    );
    const originalCwd = process.cwd();
    try {
      // No git init — bare temp dir
      process.chdir(tmpDir);

      const result = await runHook(
        "mv codegen/pitches/ready/my-slug.md codegen/pitches/shipped/my-slug.md",
      );
      const asObj = result as { block?: boolean } | null;
      assert.ok(
        asObj == null || asObj.block !== true,
        `expected pass-through (no git repo) but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  // Case 7: read-only co-mention (ls both paths) on dirty tree → pass-through
  it("passes through for ls co-mention of both paths on dirty tree", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "clean-tree-ship-ls-dirty-"),
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
      fs.writeFileSync(path.join(tmpDir, "dirty.txt"), "dirty\n");

      process.chdir(tmpDir);

      const result = await runHook(
        "ls codegen/pitches/ready/ codegen/pitches/shipped/",
      );
      const asObj = result as { block?: boolean } | null;
      assert.ok(
        asObj == null || asObj.block !== true,
        `expected pass-through for ls but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  // Case 8: grep co-mention on dirty tree → pass-through
  it("passes through for grep co-mention of both paths on dirty tree", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "clean-tree-ship-grep-dirty-"),
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
      fs.writeFileSync(path.join(tmpDir, "dirty.txt"), "dirty\n");

      process.chdir(tmpDir);

      const result = await runHook(
        "grep -r foo codegen/pitches/ready/ codegen/pitches/shipped/",
      );
      const asObj = result as { block?: boolean } | null;
      assert.ok(
        asObj == null || asObj.block !== true,
        `expected pass-through for grep but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  // Case 9: git mv ship-mv on dirty tree → block
  it("blocks git mv ship-mv on dirty tree", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "clean-tree-ship-gitmv-dirty-"),
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
      fs.writeFileSync(path.join(tmpDir, "dirty.txt"), "dirty\n");

      process.chdir(tmpDir);

      const result = await runHook(
        "git mv codegen/pitches/ready/slug.md codegen/pitches/shipped/slug.md",
      );
      const asObj = result as { block?: boolean; reason?: string } | null;
      assert.ok(
        asObj != null && asObj.block === true,
        `expected block for git mv but got: ${JSON.stringify(result)}`,
      );
      assert.ok(
        asObj.reason?.includes("working tree not clean"),
        `expected "working tree not clean" in reason but got: ${asObj.reason}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  // Case 10: chained mv on dirty tree → block
  it("blocks chained mv ship-mv on dirty tree", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "clean-tree-ship-chain-dirty-"),
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
      fs.writeFileSync(path.join(tmpDir, "dirty.txt"), "dirty\n");

      process.chdir(tmpDir);

      const result = await runHook(
        "mv codegen/pitches/ready/slug.md codegen/pitches/shipped/slug.md && date",
      );
      const asObj = result as { block?: boolean; reason?: string } | null;
      assert.ok(
        asObj != null && asObj.block === true,
        `expected block for chained mv but got: ${JSON.stringify(result)}`,
      );
      assert.ok(
        asObj.reason?.includes("working tree not clean"),
        `expected "working tree not clean" in reason but got: ${asObj.reason}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  // Case 11: echo with both paths on dirty tree → pass-through
  it("passes through for echo word co-mention of both paths on dirty tree", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "clean-tree-ship-echo-dirty-"),
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
      fs.writeFileSync(path.join(tmpDir, "dirty.txt"), "dirty\n");

      process.chdir(tmpDir);

      const result = await runHook(
        "echo remove codegen/pitches/ready/x.md codegen/pitches/shipped/y.md",
      );
      const asObj = result as { block?: boolean } | null;
      assert.ok(
        asObj == null || asObj.block !== true,
        `expected pass-through for echo but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.chdir(originalCwd);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
