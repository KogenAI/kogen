/**
 * Tests for context-factcheck-edit-gate hook.
 * Mirrors surface-level cases from context-factcheck-edit-gate_test.sh.
 * Deep scan-primitive cases are covered by the bash scan lib's own tests.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execFileSync } from "node:child_process";

describe("context-factcheck-edit-gate", { concurrency: false }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  let repoDir: string;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  beforeEach(() => {
    repoDir = fs.mkdtempSync(path.join(os.tmpdir(), "factcheck-edit-gate-pi-"));
    fs.mkdirSync(path.join(repoDir, "context"), { recursive: true });
    fs.mkdirSync(path.join(repoDir, "lib"), { recursive: true });
    execFileSync("git", ["init", "-q"], { cwd: repoDir });
    fs.writeFileSync(path.join(repoDir, "PROJECT_CONTEXT.md"), "", "utf8");
    process.env["CWD"] = repoDir;
  });

  afterEach(() => {
    delete process.env["CWD"];
    fs.rmSync(repoDir, { recursive: true, force: true });
  });

  async function runHook(
    relFilePath: string,
    toolName = "write",
    extraInput: Record<string, unknown> = {},
  ) {
    const { register } = await import("../context-factcheck-edit-gate");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName,
      toolCallId: "test-id",
      input: { file_path: path.join(repoDir, relFilePath), ...extraInput },
    });
  }

  const isAllow = (r: unknown): boolean =>
    r == null || (r as { block?: boolean }).block !== true;
  const isDeny = (r: unknown): boolean =>
    (r as { block?: boolean }).block === true;

  it("denies write with `_`->`*` corruption in projected content", async () => {
    const result = await runHook("context/foo.md", "write", {
      content: "see `lib/register*route.ex` corrupted\n",
    });
    assert.ok(isDeny(result));
  });

  it("allows write with clean projected content", async () => {
    const result = await runHook("context/foo.md", "write", {
      content: "clean content, no claims here\n",
    });
    assert.ok(isAllow(result));
  });

  it("denies edit folding to corruption", async () => {
    fs.writeFileSync(path.join(repoDir, "context/foo.md"), "old content here\n", "utf8");
    const result = await runHook("context/foo.md", "edit", {
      old_string: "old content here",
      new_string: "register*route corrupted",
    });
    assert.ok(isDeny(result));
  });

  it("denies multiedit folding to corruption", async () => {
    fs.writeFileSync(path.join(repoDir, "context/foo.md"), "old content here\n", "utf8");
    const result = await runHook("context/foo.md", "multiedit", {
      edits: [{ old_string: "old content here", new_string: "register*route corrupted" }],
    });
    assert.ok(isDeny(result));
  });

  it("allows write to non-orientation-doc path (path gate)", async () => {
    const result = await runHook("lib/foo.ex", "write", {
      content: "register*route\n",
    });
    assert.ok(isAllow(result));
  });

  it("allows bash tool with corruption-shaped payload (tool gate)", async () => {
    const result = await runHook("context/foo.md", "bash", {
      command: "echo register*route",
    });
    assert.ok(isAllow(result));
  });

  it("allows empty file_path (graceful)", async () => {
    const { register } = await import("../context-factcheck-edit-gate");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    const result = await _capturedHandler({
      toolName: "write",
      toolCallId: "test-id",
      input: { content: "x" },
    });
    assert.ok(isAllow(result));
  });

  it("allows write to context/sub/nested.md (subdir excluded)", async () => {
    fs.mkdirSync(path.join(repoDir, "context/sub"), { recursive: true });
    const result = await runHook("context/sub/nested.md", "write", {
      content: "register*route\n",
    });
    assert.ok(isAllow(result));
  });

  it("denies write to CLAUDE.md with corruption (root doc)", async () => {
    const result = await runHook("CLAUDE.md", "write", {
      content: "register*route\n",
    });
    assert.ok(isDeny(result));
  });

  it("allows write outside a git repo (fail-open)", async () => {
    const noGitDir = fs.mkdtempSync(path.join(os.tmpdir(), "factcheck-edit-gate-nogit-"));
    fs.mkdirSync(path.join(noGitDir, "context"), { recursive: true });
    process.env["CWD"] = noGitDir;
    try {
      const { register } = await import("../context-factcheck-edit-gate");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      const result = await _capturedHandler({
        toolName: "write",
        toolCallId: "test-id",
        input: {
          file_path: path.join(noGitDir, "context/foo.md"),
          content: "register*route\n",
        },
      });
      assert.ok(isAllow(result));
    } finally {
      fs.rmSync(noGitDir, { recursive: true, force: true });
    }
  });

  it("allows write referencing a REAL repo-root path (proves resolution hits the real tree, not the empty tmp mirror)", async () => {
    fs.writeFileSync(path.join(repoDir, "lib/real.ex"), "defmodule Real do\nend\n", "utf8");
    const result = await runHook("context/foo.md", "write", {
      content: "see `lib/real.ex` for details\n",
    });
    assert.ok(isAllow(result));
  });

  it("denies write referencing a STALE path that does not exist anywhere in the repo", async () => {
    const result = await runHook("context/foo.md", "write", {
      content: "see `lib/nonexistent_module.ex` for details\n",
    });
    assert.ok(isDeny(result));
  });
});
