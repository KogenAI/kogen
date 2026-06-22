/**
 * Tests for context-factcheck-guard hook.
 * Mirrors surface-level cases from context-factcheck-guard_test.sh.
 * Note: Deep git-state cases (real staged blobs) are covered by the bash twin.
 * Tests here cover the behavioral surface accessible without live git state.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as os from "node:os";
import * as fs from "node:fs";
import * as path from "node:path";
import { execSync } from "node:child_process";

function makeToolEvent(command: string, toolName = "bash") {
  return { toolName, toolCallId: "test-id", input: { command } };
}

function makeFixture(prefix: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `factcheck-pi-${prefix}-`));
  execSync("git init -q", { cwd: dir });
  execSync("git config user.email t@t", { cwd: dir });
  execSync("git config user.name t", { cwd: dir });
  execSync("git config commit.gpgsign false", { cwd: dir });
  fs.writeFileSync(
    path.join(dir, "PROJECT_CONTEXT.md"),
    "# PROJECT_CONTEXT.md\n## Domain Context Files\n",
  );
  execSync("git add PROJECT_CONTEXT.md", { cwd: dir });
  execSync('git commit -q -m "init"', { cwd: dir });
  return dir;
}

describe("context-factcheck-guard", { concurrency: 1 }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  const fixtures: string[] = [];

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, toolName = "bash") {
    const { register } = await import("../context-factcheck-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolEvent(command, toolName));
  }

  async function runHookInDir(
    dir: string,
    command: string,
    toolName = "bash",
  ) {
    const orig = process.cwd();
    process.chdir(dir);
    try {
      return await runHook(command, toolName);
    } finally {
      process.chdir(orig);
    }
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  afterEach(() => {
    // Clean up fixtures created in this test.
    // (Fixtures are tracked in fixtures array.)
  });

  // ── No orientation docs staged → passes ──────────────────────────────────
  it("no orientation docs staged → passes", async () => {
    const dir = makeFixture("no-staged");
    fixtures.push(dir);
    // Stage an unrelated file.
    fs.writeFileSync(path.join(dir, "README.md"), "readme\n");
    execSync("git add README.md", { cwd: dir });

    const result = await runHookInDir(dir, 'git commit -m "x"');
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
    );
  });

  // ── Clean named-path (exists) → passes ───────────────────────────────────
  it("clean named-path (exists) → passes", async () => {
    const dir = makeFixture("path-exists");
    fixtures.push(dir);
    fs.mkdirSync(path.join(dir, "context"), { recursive: true });
    fs.writeFileSync(path.join(dir, "context", "hooks.md"), "# hooks\n");
    execSync("git add context/hooks.md", { cwd: dir });
    execSync('git commit -q -m "seed"', { cwd: dir });
    // Stage a doc that references the real file.
    fs.writeFileSync(
      path.join(dir, "context", "x.md"),
      "See `context/hooks.md` for details.\n",
    );
    execSync("git add context/x.md", { cwd: dir });

    const result = await runHookInDir(dir, 'git commit -m "add x"');
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
    );
  });

  // ── Missing slash-path claim → deny ──────────────────────────────────────
  it("missing slash-path claim → deny", async () => {
    const dir = makeFixture("path-missing");
    fixtures.push(dir);
    fs.mkdirSync(path.join(dir, "context"), { recursive: true });
    fs.writeFileSync(
      path.join(dir, "context", "x.md"),
      "See `context/nonexistent-xyz.md` for details.\n",
    );
    execSync("git add context/x.md", { cwd: dir });

    const result = await runHookInDir(dir, 'git commit -m "add x"');
    assert.ok((result as { block?: boolean } | null)?.block === true);
  });

  // ── Bare basename (no slash) → ignored ───────────────────────────────────
  it("bare basename (no slash) → ignored (not checked)", async () => {
    const dir = makeFixture("bare-basename");
    fixtures.push(dir);
    fs.mkdirSync(path.join(dir, "context"), { recursive: true });
    fs.writeFileSync(
      path.join(dir, "context", "x.md"),
      "See `dispatch.sh` for details.\n",
    );
    execSync("git add context/x.md", { cwd: dir });

    const result = await runHookInDir(dir, 'git commit -m "add x"');
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
    );
  });

  // ── Clean count anchor with correct count → passes ───────────────────────
  it("clean count anchor with correct count → passes", async () => {
    const dir = makeFixture("count-match");
    fixtures.push(dir);
    fs.mkdirSync(path.join(dir, "hooks"), { recursive: true });
    fs.writeFileSync(path.join(dir, "hooks", "a.sh"), "#!/bin/bash\necho a\n");
    fs.writeFileSync(path.join(dir, "hooks", "b.sh"), "#!/bin/bash\necho b\n");
    fs.writeFileSync(path.join(dir, "hooks", "c.sh"), "#!/bin/bash\necho c\n");
    // Probe count: 3
    const content =
      "# PROJECT_CONTEXT.md\n<!-- count: ls hooks/*.sh | wc -l -->3\n";
    fs.writeFileSync(path.join(dir, "PROJECT_CONTEXT.md"), content);
    execSync("git add PROJECT_CONTEXT.md", { cwd: dir });

    const result = await runHookInDir(dir, 'git commit -m "test"');
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
    );
  });

  // ── Count anchor mismatch → deny ─────────────────────────────────────────
  it("count anchor mismatch (999) → deny", async () => {
    const dir = makeFixture("count-mismatch");
    fixtures.push(dir);
    fs.mkdirSync(path.join(dir, "hooks"), { recursive: true });
    fs.writeFileSync(path.join(dir, "hooks", "a.sh"), "#!/bin/bash\necho a\n");
    const content =
      "# PROJECT_CONTEXT.md\n<!-- count: ls hooks/*.sh | wc -l -->999\n";
    fs.writeFileSync(path.join(dir, "PROJECT_CONTEXT.md"), content);
    execSync("git add PROJECT_CONTEXT.md", { cwd: dir });

    const result = await runHookInDir(dir, 'git commit -m "test"');
    assert.ok((result as { block?: boolean } | null)?.block === true);
  });

  // ── Disallowed verb in probe → deny ──────────────────────────────────────
  it("disallowed verb 'git' in count probe → deny", async () => {
    const dir = makeFixture("disallowed-verb");
    fixtures.push(dir);
    fs.mkdirSync(path.join(dir, "context"), { recursive: true });
    fs.writeFileSync(
      path.join(dir, "context", "x.md"),
      "<!-- count: git log | wc -l -->5\n",
    );
    execSync("git add context/x.md", { cwd: dir });

    const result = await runHookInDir(dir, 'git commit -m "test"');
    assert.ok((result as { block?: boolean } | null)?.block === true);
  });

  // ── Malformed anchor (non-integer NNN) → deny ────────────────────────────
  it("malformed non-integer NNN → deny", async () => {
    const dir = makeFixture("malformed-nnn");
    fixtures.push(dir);
    fs.mkdirSync(path.join(dir, "context"), { recursive: true });
    fs.writeFileSync(
      path.join(dir, "context", "x.md"),
      "Some text <!-- count: ls | wc -l -->abc and more text.\n",
    );
    execSync("git add context/x.md", { cwd: dir });

    const result = await runHookInDir(dir, 'git commit -m "test"');
    assert.ok((result as { block?: boolean } | null)?.block === true);
  });

  // ── Probe exits non-zero → allow (fail-open) ─────────────────────────────
  it("probe on nonexistent path gives 0 lines, anchor 0 → allow", async () => {
    const dir = makeFixture("probe-failopen");
    fixtures.push(dir);
    fs.mkdirSync(path.join(dir, "context"), { recursive: true });
    fs.writeFileSync(
      path.join(dir, "context", "x.md"),
      "<!-- count: ls /nonexistent-xyz-factcheck-pi-test | wc -l -->0\n",
    );
    execSync("git add context/x.md", { cwd: dir });

    const result = await runHookInDir(dir, 'git commit -m "test"');
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
    );
  });

  // ── Non-orientation doc → ignored ────────────────────────────────────────
  it("non-orientation doc staged → ignored", async () => {
    const dir = makeFixture("non-orientation");
    fixtures.push(dir);
    // Stage a lib file (not an orientation doc).
    fs.writeFileSync(
      path.join(dir, "lib.ex"),
      "See `context/nonexistent-xyz.md`\n",
    );
    execSync("git add lib.ex", { cwd: dir });

    const result = await runHookInDir(dir, 'git commit -m "test"');
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
    );
  });

  // ── git status (non-commit) → passes ─────────────────────────────────────
  it("git status (non-commit) passes through", async () => {
    const result = await runHook("git status");
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
    );
  });

  // ── Read tool with git commit payload → passes ───────────────────────────
  it("Read tool with git commit payload passes through (tool guard)", async () => {
    const result = await runHook('git commit -m "x"', "read");
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
    );
  });

});
