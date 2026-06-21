/**
 * Tests for build-agent-app-confinement hook.
 * Mirrors cases from build-agent-app-confinement_test.sh.
 */

import { describe, it, before, beforeEach, after } from "node:test";
import assert from "node:assert/strict";
import * as os from "node:os";
import * as path from "node:path";
import * as fs from "node:fs";

// Synthetic build sandbox for test isolation.
const SYNTHETIC_SANDBOX = path.join(
  os.tmpdir(),
  "build-agent-confinement-sandbox",
);
const SYNTHETIC_OUTSIDE = path.join(
  os.tmpdir(),
  "build-agent-confinement-outside",
);

describe("build-agent-app-confinement", { concurrency: 1 }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(toolName: string, input: Record<string, string>) {
    const { register } = await import("../build-agent-app-confinement");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({ toolName, toolCallId: "test-id", input });
  }

  before(() => {
    fs.mkdirSync(SYNTHETIC_SANDBOX, { recursive: true });
    fs.mkdirSync(SYNTHETIC_OUTSIDE, { recursive: true });
    // Create files for tests
    fs.mkdirSync(path.join(SYNTHETIC_SANDBOX, "lib"), { recursive: true });
    fs.writeFileSync(path.join(SYNTHETIC_SANDBOX, "lib", "foo.ex"), "");
    fs.writeFileSync(path.join(SYNTHETIC_OUTSIDE, "secrets.txt"), "");
    process.env["CODEGEN_BUILD_CWD"] = SYNTHETIC_SANDBOX;
  });

  after(() => {
    delete process.env["CODEGEN_BUILD_CWD"];
    fs.rmSync(SYNTHETIC_SANDBOX, { recursive: true, force: true });
    fs.rmSync(SYNTHETIC_OUTSIDE, { recursive: true, force: true });
  });

  beforeEach(() => {
    // Ensure CODEGEN_BUILD_CWD is always reset to sandbox before each test
    process.env["CODEGEN_BUILD_CWD"] = SYNTHETIC_SANDBOX;
  });

  it("inert when CODEGEN_BUILD_CWD unset — write outside allowed", async () => {
    const saved = process.env["CODEGEN_BUILD_CWD"];
    delete process.env["CODEGEN_BUILD_CWD"];
    try {
      const result = await runHook("write", {
        path: path.join(SYNTHETIC_OUTSIDE, "secrets.txt"),
      });
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      if (saved !== undefined) process.env["CODEGEN_BUILD_CWD"] = saved;
    }
  });

  it("allows write inside sandbox", async () => {
    const result = await runHook("write", {
      path: path.join(SYNTHETIC_SANDBOX, "lib", "foo.ex"),
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies write outside sandbox", async () => {
    const result = await runHook("write", {
      path: path.join(SYNTHETIC_OUTSIDE, "secrets.txt"),
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows /tmp escape hatch", async () => {
    const result = await runHook("write", { path: "/tmp/scratch.txt" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows /private/tmp escape hatch (macOS symlink)", async () => {
    const result = await runHook("write", {
      path: "/private/tmp/scratch.txt",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies edit outside sandbox", async () => {
    const result = await runHook("edit", {
      path: path.join(SYNTHETIC_OUTSIDE, "secrets.txt"),
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("denies multiEdit outside sandbox", async () => {
    const result = await runHook("multiEdit", {
      path: path.join(SYNTHETIC_OUTSIDE, "secrets.txt"),
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("sibling-dir prefix does not false-allow (/sandbox must not match /sandboxOther)", async () => {
    // sandboxOther shares the prefix of SYNTHETIC_SANDBOX but is a sibling
    const siblingDir = SYNTHETIC_SANDBOX + "Other";
    fs.mkdirSync(siblingDir, { recursive: true });
    try {
      const siblingFile = path.join(siblingDir, "file.txt");
      fs.writeFileSync(siblingFile, "");
      const result = await runHook("write", { path: siblingFile });
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(siblingDir, { recursive: true, force: true });
    }
  });

  it("allows relative path resolving inside sandbox", async () => {
    // Relative path "lib/new.ex" resolves under canonCwd → allowed
    const result = await runHook("write", { path: "lib/new.ex" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through non-write tool (read) even outside sandbox", async () => {
    const result = await runHook("read", {
      path: path.join(SYNTHETIC_OUTSIDE, "secrets.txt"),
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
