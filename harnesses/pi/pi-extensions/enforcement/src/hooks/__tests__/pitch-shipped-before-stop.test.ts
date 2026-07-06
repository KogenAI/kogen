/**
 * Tests for pitch-shipped-before-stop hook.
 * Mirrors cases from pitch-shipped-before-stop_test.sh.
 * Note: Pi session_shutdown is observe-only — warns to stderr, cannot block.
 * Tests verify no crash and correct warning behavior.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

// concurrency: false — tests mutate process.env (CWD, SESSION_ID) and
// process.stderr.write, which are process-global. Serialise to avoid races.
describe("pitch-shipped-before-stop", { concurrency: false }, () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "pitch-shipped-before-stop-test-"),
    );
    fs.mkdirSync(path.join(tmpDir, "codegen", "logging"), { recursive: true });
    fs.mkdirSync(path.join(tmpDir, "codegen", "pitches", "ready"), {
      recursive: true,
    });
    fs.mkdirSync(path.join(tmpDir, "codegen", "pitches", "shipped"), {
      recursive: true,
    });
  });

  afterEach(() => {
    // Clean up all counter files from this test suite — both the tmpDir-basename
    // derived file (tests using default session ID) and any fixed session IDs
    // used by specific tests (e.g. "name-check-sess-13"). Without this broad
    // sweep, fixed-ID counter files accumulate across repeated runs; every ~3rd
    // run hits the retry cap (>= 2) and runHook() returns early without warning,
    // causing assertion failures.
    const tmpBase = os.tmpdir();
    try {
      const files = fs.readdirSync(tmpBase);
      files.forEach((f) => {
        if (/^claude-autoship-guard-.*\.count$/.test(f)) {
          fs.rmSync(path.join(tmpBase, f), { force: true });
        }
      });
    } catch {
      // tmpBase read failure; ignore — cleanup is best-effort
    }

    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
    delete process.env["SESSION_ID"];
    delete process.env["CLAUDE_ROLE"];
    delete process.env["PI_ROLE"];
    delete process.env["CODEGEN_NO_AUTOSHIP"];
  });

  /**
   * Write a JSONL cycle log with the canonical <ts>_<slug>_cycle.jsonl name.
   * Default slug is "my-feature" to match writePitchReady("my-feature.md").
   * `committerPresent` controls whether a committer role event is appended
   * (the old fixtures encoded this via "## committer Section" markdown text
   * in the raw body — under JSONL this is a structured event instead).
   */
  function writeLog(committerPresent: boolean, slug = "my-feature"): void {
    const logPath = path.join(
      tmpDir,
      "codegen",
      "logging",
      `20260601_123456_${slug}_cycle.jsonl`,
    );
    const lines = [
      JSON.stringify({ ev: "init", pitch: slug, path: "", stamp: {} }),
    ];
    if (committerPresent) {
      lines.push(
        JSON.stringify({ ev: "role", role: "committer", body: "Committed." }),
      );
    } else {
      lines.push(
        JSON.stringify({
          ev: "role",
          role: "reviewer-phoenix",
          body: "QUALITY APPROVED",
        }),
      );
    }
    fs.writeFileSync(logPath, lines.join("\n") + "\n");
  }

  /**
   * Write a JSONL cycle log with no init event and no slug segment in the
   * filename (simulates a free-form/never-codegen-log-init'd log).
   */
  function writeNoSlugLog(filename: string): void {
    const line = JSON.stringify({
      ev: "role",
      role: "committer",
      body: "Committed.",
    });
    fs.writeFileSync(
      path.join(tmpDir, "codegen", "logging", filename),
      line + "\n",
    );
  }

  function writePitchReady(name: string): void {
    fs.writeFileSync(
      path.join(tmpDir, "codegen", "pitches", "ready", name),
      "# Pitch\n",
    );
  }

  function writePitchShipped(name: string): void {
    fs.writeFileSync(
      path.join(tmpDir, "codegen", "pitches", "shipped", name),
      "# Pitch\n",
    );
  }

  /**
   * Run the hook and return captured stderr.
   * Session ID defaults to tmpDir basename so each test run gets a unique
   * counter file; afterEach cleans it up by the same derivation.
   * Pass an explicit sessionId only when the test pre-seeds a counter file
   * with a known name (tests 8, 11) — those tests clean up their own files.
   */
  async function runHook(
    localTmpDir: string,
    sessionId?: string,
  ): Promise<string> {
    const effectiveSessionId = sessionId ?? path.basename(localTmpDir);
    process.env["CWD"] = localTmpDir;
    process.env["SESSION_ID"] = effectiveSessionId;

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../pitch-shipped-before-stop");
    mod.register(
      localMockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );

    let stderrOutput = "";
    const origStderrWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (s: string) => {
      stderrOutput += s;
      return true;
    };
    try {
      await capturedHandler!({
        toolName: "session_shutdown",
        toolCallId: "test-id",
        input: {},
      });
    } finally {
      process.stderr.write = origStderrWrite;
    }
    return stderrOutput;
  }

  // ── Test 1: warns when committer-section present + pitch in ready/ ─────────
  it("warns when committer section present and pitch in ready/", async () => {
    writeLog(true);
    writePitchReady("my-feature.md");
    const stderrOutput = await runHook(tmpDir);
    assert.ok(
      stderrOutput.includes("pitch-shipped-before-stop"),
      "expected warning on stderr",
    );
    assert.ok(stderrOutput.includes("my-feature.md"));
  });

  // ── Test 2: no warning when pitch in shipped/ (no ready/ pitch) ────────────
  it("does not warn when no pitches in ready/", async () => {
    writeLog(true);
    writePitchShipped("my-feature.md");
    const stderrOutput = await runHook(tmpDir);
    assert.ok(
      !stderrOutput.includes("pitch-shipped-before-stop"),
      "expected no warning",
    );
  });

  // ── Test 3: no warning when no step log ────────────────────────────────────
  it("does not warn when no step log exists", async () => {
    writePitchReady("my-feature.md");
    const stderrOutput = await runHook(tmpDir, "no-log-sess-3");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 4: no warning when committer section absent ──────────────────────
  it("does not warn when committer section absent", async () => {
    writeLog(false);
    writePitchReady("my-feature.md");
    const stderrOutput = await runHook(tmpDir, "no-committer-sess-4");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 5a: shape role bypass (isBuildMode() false) — regression fix ─────
  it("bypasses when CLAUDE_ROLE=shape (investigative bypass)", async () => {
    process.env["CLAUDE_ROLE"] = "shape";
    writeLog(true);
    writePitchReady("my-feature.md");
    const stderrOutput = await runHook(tmpDir, "shape-sess-5a");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 5b: CLAUDE_ROLE=build still enforces (real build, not investigative) ─
  it("still warns when CLAUDE_ROLE=build (explicit build role enforces)", async () => {
    process.env["CLAUDE_ROLE"] = "build";
    writeLog(true);
    writePitchReady("my-feature.md");
    const stderrOutput = await runHook(tmpDir, "build-sess-5b");
    assert.ok(stderrOutput.includes("WARNING"), "expected warning");
  });

  // ── Test 6: bypass CODEGEN_NO_AUTOSHIP=1 ──────────────────────────────────
  it("bypasses when CODEGEN_NO_AUTOSHIP is set", async () => {
    process.env["CODEGEN_NO_AUTOSHIP"] = "1";
    writeLog(true);
    writePitchReady("my-feature.md");
    const stderrOutput = await runHook(tmpDir, "no-autoship-sess-6");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 7: bypass PI_ROLE=shape (investigative bypass, Pi precedence) ────
  it("bypasses when PI_ROLE=shape", async () => {
    process.env["PI_ROLE"] = "shape";
    writeLog(true);
    writePitchReady("my-feature.md");
    const stderrOutput = await runHook(tmpDir, "pi-role-sess-7");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 8: retry cap stops warning at 2 ──────────────────────────────────
  it("stops warning after retry cap (count >= 2)", async () => {
    writeLog(true);
    writePitchReady("my-feature.md");

    const counterFile = path.join(
      os.tmpdir(),
      "claude-autoship-guard-cap-sess-8.count",
    );
    fs.writeFileSync(counterFile, "2");

    const stderrOutput = await runHook(tmpDir, "cap-sess-8");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning at cap");

    fs.rmSync(counterFile, { force: true });
  });

  // ── Test 9: increments counter on first warn ───────────────────────────────
  it("increments counter on first warning", async () => {
    writeLog(true);
    writePitchReady("my-feature.md");

    const counterFile = path.join(
      os.tmpdir(),
      "claude-autoship-guard-count-sess-9.count",
    );
    fs.rmSync(counterFile, { force: true });

    await runHook(tmpDir, "count-sess-9");
    const cnt = parseInt(
      fs.readFileSync(counterFile, "utf8").trim() || "0",
      10,
    );
    assert.equal(cnt, 1, "expected counter = 1 after first warning");
    fs.rmSync(counterFile, { force: true });
  });

  // ── Test 10: no warning when no pitches/ dir ──────────────────────────────
  it("does not crash when no pitches dir exists", async () => {
    writeLog(true);
    // Remove ready/ dir
    fs.rmSync(path.join(tmpDir, "codegen", "pitches", "ready"), {
      recursive: true,
      force: true,
    });
    const stderrOutput = await runHook(tmpDir, "no-pitches-sess-10");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 11: second warn still fires before cap ───────────────────────────
  it("warns again at count=1 (below cap)", async () => {
    writeLog(true);
    writePitchReady("my-feature.md");

    const counterFile = path.join(
      os.tmpdir(),
      "claude-autoship-guard-second-warn-sess-11.count",
    );
    fs.writeFileSync(counterFile, "1");

    const stderrOutput = await runHook(tmpDir, "second-warn-sess-11");
    assert.ok(stderrOutput.includes("WARNING"), "expected warning at count=1");
    fs.rmSync(counterFile, { force: true });
  });

  // ── Test 12: no warning when no logging dir ───────────────────────────────
  it("does not crash when no logging dir exists", async () => {
    fs.rmSync(path.join(tmpDir, "codegen", "logging"), {
      recursive: true,
      force: true,
    });
    writePitchReady("my-feature.md");
    const stderrOutput = await runHook(tmpDir, "no-logging-sess-12");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 13: warning message names the pitch basename ─────────────────────
  it("warning message includes pitch basename", async () => {
    writeLog(true, "orchestrator-discipline");
    writePitchReady("orchestrator-discipline.md");
    const stderrOutput = await runHook(tmpDir, "name-check-sess-13");
    assert.ok(
      stderrOutput.includes("orchestrator-discipline.md"),
      "expected pitch basename in warning",
    );
  });

  // ── Test 15: slug-match + committer-section + warn contains slug filename ──
  it("warning references slug filename when slug-match + committer + ready/", async () => {
    writeLog(true, "my-feature");
    writePitchReady("my-feature.md");
    const stderrOutput = await runHook(tmpDir, "slug-match-sess-15");
    assert.ok(
      stderrOutput.includes("pitch-shipped-before-stop"),
      "expected warning on stderr",
    );
    assert.ok(
      stderrOutput.includes("my-feature.md"),
      "expected slug filename in warning",
    );
  });

  // ── Test 16: slug pitch absent from ready/ → no warning ──────────────────
  // Incident case: build session for pitch X; unrelated pitch Y in ready/.
  // New logic: only ships the pitch matching THIS session's slug (X), not Y.
  it("does not warn when slug pitch is absent from ready/ (unrelated pitch present)", async () => {
    // Log slug is "foo"; ready/ only has "unrelated-pitch.md", not "foo.md"
    writeLog(true, "foo");
    writePitchReady("unrelated-pitch.md");
    const stderrOutput = await runHook(tmpDir, "slug-absent-sess-16");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 17: free-form log (no slug) → no warning ────────────────────────
  it("does not warn when log has no slug (free-form session)", async () => {
    // Log has no init event and filename has no slug segment: <ts>_cycle.jsonl
    writeNoSlugLog("20260601_123456_cycle.jsonl");
    writePitchReady("anything.md");
    const stderrOutput = await runHook(tmpDir, "free-form-sess-17");
    assert.ok(!stderrOutput.includes("WARNING"), "expected no warning");
  });

  // ── Test 14: does not block (observe-only) ────────────────────────────────
  it("returns null/undefined (observe-only — cannot block)", async () => {
    writeLog(true);
    writePitchReady("my-feature.md");

    // Run hook directly to capture return value alongside stderr
    process.env["CWD"] = tmpDir;
    process.env["SESSION_ID"] = "observe-sess-14";

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../pitch-shipped-before-stop");
    mod.register(
      localMockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );

    let result: unknown;
    const origStderrWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (_s: string) => true;
    try {
      result = await capturedHandler!({
        toolName: "session_shutdown",
        toolCallId: "test-id",
        input: {},
      });
    } finally {
      process.stderr.write = origStderrWrite;
    }

    // session_shutdown handlers must NOT return a block result
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
      "Pi session_shutdown should not return block",
    );
  });
});
