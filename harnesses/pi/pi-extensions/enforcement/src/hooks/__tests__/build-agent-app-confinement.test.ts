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
//
// Rooted under os.homedir(), NOT os.tmpdir(): the hook under test grants an
// unconditional scratch escape hatch to any path under /tmp/ or
// /private/tmp/ (see build-agent-app-confinement.ts). On Linux os.tmpdir()
// resolves to /tmp, so a fixture rooted there would make every
// "denies ... outside sandbox" assertion unreachable — the hook always
// allows it before the sandbox-prefix check runs.
const FIXTURE_ROOT = path.join(
  os.homedir(),
  ".build-agent-confinement-fixture",
);
const SYNTHETIC_SANDBOX = path.join(FIXTURE_ROOT, "sandbox");
const SYNTHETIC_OUTSIDE = path.join(FIXTURE_ROOT, "outside");

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
    fs.rmSync(FIXTURE_ROOT, { recursive: true, force: true });
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
    fs.rmSync(FIXTURE_ROOT, { recursive: true, force: true });
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
    // Relative path "lib/new.ex" resolves under process.cwd() — mirrors a
    // real build where dispatch execs with cwd == CODEGEN_BUILD_CWD.
    const savedCwd = process.cwd();
    process.chdir(SYNTHETIC_SANDBOX);
    try {
      const result = await runHook("write", { path: "lib/new.ex" });
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    } finally {
      process.chdir(savedCwd);
    }
  });

  it("passes through non-write tool (read) even outside sandbox", async () => {
    const result = await runHook("read", {
      path: path.join(SYNTHETIC_OUTSIDE, "secrets.txt"),
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── leg A: Bash write-vocab coverage ──────────────────────────────────
  it("leg A: denies bash redirect through escaping symlink", async () => {
    const linkPath = path.join(SYNTHETIC_SANDBOX, "escape_link");
    fs.symlinkSync(
      path.join(SYNTHETIC_OUTSIDE, "secrets.txt"),
      linkPath,
    );
    try {
      const result = await runHook("bash", {
        command: `echo pwned > ${linkPath}`,
      });
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(linkPath, { force: true });
    }
  });

  it("leg A: allows bash redirect inside sandbox", async () => {
    const result = await runHook("bash", {
      command: `echo hi > ${path.join(SYNTHETIC_SANDBOX, "lib", "new2.ex")}`,
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("leg A: denies bash cp destination outside sandbox", async () => {
    const src = path.join(SYNTHETIC_SANDBOX, "src.txt");
    fs.writeFileSync(src, "");
    const dst = path.join(SYNTHETIC_OUTSIDE, "dst.txt");
    try {
      const result = await runHook("bash", { command: `cp ${src} ${dst}` });
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(src, { force: true });
    }
  });

  it("leg A: denies cd .. combined with redirect (fail-closed)", async () => {
    const result = await runHook("bash", {
      command: `cd ${SYNTHETIC_SANDBOX} && cd .. && echo x > file.txt`,
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("leg A: allows genuine /tmp scratch write via bash, sandbox elsewhere", async () => {
    const result = await runHook("bash", {
      command: `echo hi > /tmp/confinement-ts-scratch-${process.pid}.txt`,
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("leg A: allows bash command with no write-vocab", async () => {
    const result = await runHook("bash", { command: "mix test test/foo_test.exs" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── leg B: canonicalize-before-hatch ───────────────────────────────────
  it("leg B: denies write to /tmp-sandboxed escaping symlink", async () => {
    const tmpSandbox = fs.mkdtempSync(path.join(os.tmpdir(), "confb-sandbox-"));
    const tmpOutside = fs.mkdtempSync(path.join(os.tmpdir(), "confb-outside-"));
    const outsideFile = path.join(tmpOutside, "secret.txt");
    fs.writeFileSync(outsideFile, "");
    const linkPath = path.join(tmpSandbox, "CLAUDE.md");
    fs.symlinkSync(outsideFile, linkPath);
    const saved = process.env["CODEGEN_BUILD_CWD"];
    process.env["CODEGEN_BUILD_CWD"] = tmpSandbox;
    try {
      const result = await runHook("write", { path: linkPath });
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      if (saved !== undefined) process.env["CODEGEN_BUILD_CWD"] = saved;
      fs.rmSync(tmpSandbox, { recursive: true, force: true });
      fs.rmSync(tmpOutside, { recursive: true, force: true });
    }
  });

  it("leg A: allows bash redirect to /dev/null (ubiquitous idiom)", async () => {
    const result = await runHook("bash", { command: "mix test 2>/dev/null" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("leg B: allows real file under /tmp sandbox", async () => {
    const tmpSandbox = fs.mkdtempSync(path.join(os.tmpdir(), "confb2-sandbox-"));
    const realFile = path.join(tmpSandbox, "real.txt");
    fs.writeFileSync(realFile, "");
    const saved = process.env["CODEGEN_BUILD_CWD"];
    process.env["CODEGEN_BUILD_CWD"] = tmpSandbox;
    try {
      const result = await runHook("write", { path: realFile });
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    } finally {
      if (saved !== undefined) process.env["CODEGEN_BUILD_CWD"] = saved;
      fs.rmSync(tmpSandbox, { recursive: true, force: true });
    }
  });
});
