/**
 * Tests for build-queue-continuity hook.
 * Mirrors cases from build-queue-continuity_test.sh.
 * Note: Pi session_shutdown is observe-only — warns to stderr, cannot block.
 * Tests verify correct warning behavior.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

// concurrency: false — tests mutate process.env (CWD) and
// process.stderr.write, which are process-global. Serialise to avoid races.
describe("build-queue-continuity", { concurrency: false }, () => {
  let tmpDir: string;

  beforeEach(() => {
    delete process.env["CWD"];
    delete process.env["PI_ROLE"];
    delete process.env["CLAUDE_ROLE"];
    tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "build-queue-continuity-test-"),
    );
    fs.mkdirSync(path.join(tmpDir, "codegen", "gate-pending"), {
      recursive: true,
    });
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
    delete process.env["PI_ROLE"];
    delete process.env["CLAUDE_ROLE"];
  });

  function writeManifest(data: object): void {
    fs.writeFileSync(
      path.join(tmpDir, "codegen", "gate-pending", "build-queue.json"),
      JSON.stringify(data),
    );
  }

  function writeGateResult(verdict: string): void {
    fs.writeFileSync(
      path.join(tmpDir, "codegen", "gate-pending", "gate-result.json"),
      JSON.stringify({ verdict }),
    );
  }

  async function runHook(localTmpDir: string): Promise<string> {
    process.env["CWD"] = localTmpDir;

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../build-queue-continuity");
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

  it("warns when manifest has remaining pitches and gate is clear", async () => {
    writeManifest({
      slugs: ["a", "b", "c"],
      position: 1,
      started_at: "2026-01-01T00:00:00Z",
    });
    writeGateResult("clear");
    const stderrOutput = await runHook(tmpDir);
    assert.ok(stderrOutput.includes("WARNING"), "expected WARNING in stderr output");
    assert.ok(stderrOutput.includes("b"), "expected next slug in warning message");
  });

  it("skips shipped slug at manifest position in favor of next live slug", async () => {
    writeManifest({
      slugs: ["a", "b", "c"],
      position: 1,
      started_at: "2026-01-01T00:00:00Z",
    });
    writeGateResult("clear");
    fs.mkdirSync(path.join(tmpDir, "codegen", "pitches", "shipped"), {
      recursive: true,
    });
    fs.writeFileSync(
      path.join(tmpDir, "codegen", "pitches", "shipped", "b.md"),
      "Pitch: b\n",
    );
    const stderrOutput = await runHook(tmpDir);
    assert.ok(stderrOutput.includes("WARNING"), "expected WARNING in stderr output");
    assert.ok(!stderrOutput.includes("next: b"), "expected shipped slug to be skipped");
    assert.ok(stderrOutput.includes("next: c"), "expected next live slug to be nominated");
  });

  it("does not warn when queue is exhausted (position >= len)", async () => {
    writeManifest({
      slugs: ["a", "b"],
      position: 2,
      started_at: "2026-01-01T00:00:00Z",
    });
    writeGateResult("clear");
    const stderrOutput = await runHook(tmpDir);
    assert.ok(
      !stderrOutput.includes("WARNING"),
      "expected no warning when exhausted",
    );
  });

  // ── Test 3: no warning when no manifest file ─────────────────────────────────
  it("does not warn when no manifest file exists", async () => {
    const stderrOutput = await runHook(tmpDir);
    assert.ok(
      !stderrOutput.includes("WARNING"),
      "expected no warning when manifest absent",
    );
  });

  // ── Test 4: no warning when gate verdict=failed ───────────────────────────────
  it("does not warn when gate verdict is failed (mid-queue halt)", async () => {
    writeManifest({
      slugs: ["a", "b", "c"],
      position: 1,
      started_at: "2026-01-01T00:00:00Z",
    });
    writeGateResult("failed");
    const stderrOutput = await runHook(tmpDir);
    assert.ok(
      !stderrOutput.includes("WARNING"),
      "expected no warning on gate failure",
    );
  });

  // ── Test 5: no warning when manifest is corrupt JSON ─────────────────────────
  it("does not warn when manifest is corrupt JSON (fail-open)", async () => {
    fs.writeFileSync(
      path.join(tmpDir, "codegen", "gate-pending", "build-queue.json"),
      "{ not json at all",
    );
    const stderrOutput = await runHook(tmpDir);
    assert.ok(
      !stderrOutput.includes("WARNING"),
      "expected no warning on corrupt manifest",
    );
  });

  // ── Test 6: no warning when manifest missing position key ─────────────────────
  it("does not warn when manifest is missing position key (fail-open)", async () => {
    writeManifest({ slugs: ["a", "b"] });
    const stderrOutput = await runHook(tmpDir);
    assert.ok(
      !stderrOutput.includes("WARNING"),
      "expected no warning when position key absent",
    );
  });

  // ── Test 7: warns when manifest has remaining + no gate-result.json ───────────
  it("warns when manifest has remaining pitches and no gate-result.json", async () => {
    writeManifest({
      slugs: ["a", "b", "c"],
      position: 0,
      started_at: "2026-01-01T00:00:00Z",
    });
    // No gate-result.json — empty verdict means not failed → should warn
    const stderrOutput = await runHook(tmpDir);
    assert.ok(
      stderrOutput.includes("WARNING"),
      "expected warning when no gate-result.json and pitches remain",
    );
  });

  // ── Test 8: no warning when PI_ROLE=shape (investigative mode) ───────────────
  it("does not warn when PI_ROLE=shape (investigative mode — build-runtime gate skipped)", async () => {
    writeManifest({
      slugs: ["a", "b", "c"],
      position: 1,
      started_at: "2026-01-01T00:00:00Z",
    });
    writeGateResult("clear");
    process.env["PI_ROLE"] = "shape";
    const stderrOutput = await runHook(tmpDir);
    assert.ok(
      !stderrOutput.includes("WARNING"),
      "expected no warning when PI_ROLE=shape (investigative mode)",
    );
  });
});
