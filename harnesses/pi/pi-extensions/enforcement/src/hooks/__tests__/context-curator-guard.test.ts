/**
 * Tests for context-curator-guard hook.
 * Mirrors cases from context-curator-guard_test.sh.
 * Uses relative paths for file_path (same convention as committer-write-allowlist tests).
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("context-curator-guard", { concurrency: false }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  beforeEach(() => {
    process.env["AGENT_TYPE"] = "context-curator";
  });

  afterEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  async function runHook(
    filePath: string,
    toolName = "write",
    agentType = "context-curator",
    extraInput: Record<string, unknown> = {},
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../context-curator-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName,
      toolCallId: "test-id",
      input: { file_path: filePath, ...extraInput },
    });
  }

  // Helper: capture stderr during a hook call. Restores in finally block.
  async function runHookCaptureStderr(
    filePath: string,
    toolName: string,
    extraInput: Record<string, unknown> = {},
  ): Promise<{ result: unknown; stderr: string }> {
    let stderr = "";
    const originalStderr = process.stderr.write.bind(process.stderr);
    try {
      process.stderr.write = (str: string | Uint8Array) => {
        stderr += str.toString();
        return true;
      };
      const result = await runHook(filePath, toolName, "context-curator", extraInput);
      return { result, stderr };
    } finally {
      process.stderr.write = originalStderr as typeof process.stderr.write;
    }
  }

  const isAllow = (r: unknown): boolean =>
    r == null || (r as { block?: boolean }).block !== true;
  const warned = (s: string): boolean =>
    s.includes("context-curator-guard") && s.includes("WARNING");
  // Produce n newline-terminated lines of content.
  const lines = (n: number): string => (n > 0 ? "x\n".repeat(n) : "");

  // ─── Original allow/deny cases ───────────────────────────────────────────

  it("allows non-curator agent unconditionally", async () => {
    const result = await runHook(
      "lib/foo.ex",
      "write",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows curator writing to context/**", async () => {
    const result = await runHook("context/foo.md");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows curator writing to codegen/rules/**", async () => {
    const result = await runHook("codegen/rules/some-rule.md");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows curator writing to codegen/logging/**", async () => {
    const result = await runHook(
      "codegen/logging/20260601_120000_session.md",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies curator writing to lib/foo.ex", async () => {
    const result = await runHook("lib/foo.ex");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("denies curator writing to shared/rules/foo.md (not codegen/rules/)", async () => {
    const result = await runHook("shared/rules/foo.md");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows empty file_path (fail-open)", async () => {
    const result = await runHook("");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows non-write/edit tool (bash) for curator", async () => {
    const result = await runHook("lib/foo.ex", "bash");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows curator using edit tool to context/", async () => {
    const result = await runHook("context/dev.md", "edit");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies curator using edit tool outside allowed surface", async () => {
    const result = await runHook("priv/repo/migrations/001.exs", "edit");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ─── PROJECT_CONTEXT.md allow cases ────────────────────────────────────────

  it("allows curator writing to codegen/PROJECT_CONTEXT.md", async () => {
    const result = await runHook("codegen/PROJECT_CONTEXT.md", "edit");
    assert.ok(isAllow(result));
  });

  it("allows curator writing to PROJECT_CONTEXT.md (root)", async () => {
    const result = await runHook("PROJECT_CONTEXT.md", "edit");
    assert.ok(isAllow(result));
  });

  it("denies curator writing to PROJECT_CONTEXT.md.bak (anchor)", async () => {
    const result = await runHook("PROJECT_CONTEXT.md.bak", "edit");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ─── Warn-only cap cases ─────────────────────────────────────────────────
  // All over-cap cases must be ALLOWED (no block). Warn appears on stderr only.

  it("W-1: edit growing _core file past 50 emits warning but allows", async () => {
    // Create a temp file whose path contains /codegen/rules/_core/
    // with 48 lines on disk. Edit adds 6 lines, removes 1 → projected 53 > 50.
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "pi-ccg-test-core-"),
    );
    const coreDir = path.join(tmpDir, "codegen", "rules", "_core");
    fs.mkdirSync(coreDir, { recursive: true });
    const filePath = path.join(coreDir, "bash-discipline.md");
    fs.writeFileSync(filePath, lines(48));

    try {
      const { result, stderr } = await runHookCaptureStderr(filePath, "edit", {
        old_string: "x\n",
        new_string: lines(6),
      });
      assert.ok(isAllow(result), "over-cap _core edit must be allowed");
      assert.ok(
        warned(stderr),
        `Expected warning on stderr for _core over-cap, got: ${stderr}`,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("W-2: edit growing roles file past 150 emits warning but allows", async () => {
    // 148 lines on disk, edit: remove 1, add 6 → projected 153 > 150.
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "pi-ccg-test-roles-"),
    );
    const rolesDir = path.join(tmpDir, "codegen", "rules", "roles");
    fs.mkdirSync(rolesDir, { recursive: true });
    const filePath = path.join(rolesDir, "developer.md");
    fs.writeFileSync(filePath, lines(148));

    try {
      const { result, stderr } = await runHookCaptureStderr(filePath, "edit", {
        old_string: "x\n",
        new_string: lines(6),
      });
      assert.ok(isAllow(result), "over-cap roles edit must be allowed");
      assert.ok(
        warned(stderr),
        `Expected warning on stderr for roles over-cap, got: ${stderr}`,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("W-3: edit keeping roles file under cap emits no warning", async () => {
    // 10 lines on disk, edit: remove 1, add 1 → projected 10 ≤ 150.
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "pi-ccg-test-under-"),
    );
    const rolesDir = path.join(tmpDir, "codegen", "rules", "roles");
    fs.mkdirSync(rolesDir, { recursive: true });
    const filePath = path.join(rolesDir, "developer.md");
    fs.writeFileSync(filePath, lines(10));

    try {
      const { result, stderr } = await runHookCaptureStderr(filePath, "edit", {
        old_string: "x\n",
        new_string: "y\n",
      });
      assert.ok(isAllow(result), "under-cap roles edit must be allowed");
      assert.ok(
        !warned(stderr),
        `Expected no warning for under-cap roles edit, got: ${stderr}`,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("W-4: write content over 50 to _core path emits warning but allows", async () => {
    // Write replaces file entirely — projected = newlines in content (55) > 50.
    // No on-disk file needed for Write projection.
    const { result, stderr } = await runHookCaptureStderr(
      "codegen/rules/_core/new.md",
      "write",
      { content: lines(55) },
    );
    assert.ok(isAllow(result), "over-cap _core write must be allowed");
    assert.ok(
      warned(stderr),
      `Expected warning on stderr for _core write over-cap, got: ${stderr}`,
    );
  });

  it("W-5: missing payload on _core path does not warn (fail-open)", async () => {
    // No old_string or new_string → both empty → fail-open, no warning.
    const { result, stderr } = await runHookCaptureStderr(
      "codegen/rules/_core/bash-discipline.md",
      "edit",
      {}, // no old_string/new_string
    );
    assert.ok(isAllow(result), "missing payload must be allowed (fail-open)");
    assert.ok(
      !warned(stderr),
      `Expected no warning for missing payload, got: ${stderr}`,
    );
  });

  it("W-6: context path with large content does not warn (not cap-gated)", async () => {
    // context/** is allowed early-return before warnIfOverCap is called.
    const { result, stderr } = await runHookCaptureStderr(
      "context/foo.md",
      "edit",
      { old_string: "a", new_string: lines(99) },
    );
    assert.ok(isAllow(result), "context path must be allowed");
    assert.ok(
      !warned(stderr),
      `Expected no warning for context path, got: ${stderr}`,
    );
  });
});
