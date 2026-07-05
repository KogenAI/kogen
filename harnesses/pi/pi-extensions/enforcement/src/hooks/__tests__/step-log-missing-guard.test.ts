/**
 * Tests for step-log-missing-guard hook.
 * Note: Pi session_shutdown is observe-only — warns to stderr, cannot block.
 * Note: This is a reduced-fidelity twin (no transcript access in Pi).
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("step-log-missing-guard", { concurrency: false }, () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "step-log-missing-guard-test-"),
    );
    process.env["CWD"] = tmpDir;
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
    delete process.env["PI_ROLE"];
  });

  async function runHook(): Promise<string> {
    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../step-log-missing-guard");
    mod.register(
      localMockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );

    let stderrOutput = "";
    const origWrite = process.stderr.write.bind(process.stderr);
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
      process.stderr.write = origWrite;
    }
    return stderrOutput;
  }

  it("does not crash when no logging dir exists (fail-open)", async () => {
    // No codegen/logging/ created — should silently pass.
    const stderr = await runHook();
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("does not warn when canonical session log present", async () => {
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    fs.writeFileSync(
      path.join(loggingDir, "20260601_120000_my-feature_session.md"),
      "# Session\n",
    );
    const stderr = await runHook();
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("does not warn when canonical step log present", async () => {
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    fs.writeFileSync(
      path.join(loggingDir, "20260601_120000_step1_my-feature.md"),
      "# Step\n",
    );
    const stderr = await runHook();
    assert.ok(!stderr.includes("WARNING"), "expected no warning");
  });

  it("does not warn when only progress log exists (no session logs)", async () => {
    // progress.md is not a session/step log — should not suppress warning
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    // Write a recently-modified progress file
    const progressPath = path.join(loggingDir, "20260601_progress.md");
    fs.writeFileSync(progressPath, "# Progress\n");
    // The canonical regex excludes progress files, so this should warn
    const stderr = await runHook();
    assert.ok(stderr.includes("step-log-missing-guard"), "expected warning");
  });

  it("warns when logging dir is recent but has no canonical logs", async () => {
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    // Write a non-canonical file
    fs.writeFileSync(path.join(loggingDir, "random-notes.md"), "notes\n");
    const stderr = await runHook();
    assert.ok(stderr.includes("step-log-missing-guard"), "expected warning");
  });

  it("does not crash when logging dir is empty", async () => {
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    const stderr = await runHook();
    // Empty dir → no .md files → should silently return
    assert.ok(!stderr.includes("WARNING"), "expected no warning on empty dir");
  });

  it("never returns block result (observe-only)", async () => {
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    fs.writeFileSync(path.join(loggingDir, "random-notes.md"), "notes\n");

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../step-log-missing-guard");
    mod.register(
      localMockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );

    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (_s: string) => true;
    let result: unknown;
    try {
      result = await capturedHandler!({
        toolName: "session_shutdown",
        toolCallId: "test-id",
        input: {},
      });
    } finally {
      process.stderr.write = origWrite;
    }
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
      "Pi session_shutdown must not block",
    );
  });

  it("does not warn when PI_ROLE=shape (investigative mode — build-runtime gate skipped)", async () => {
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    // Non-canonical file that would normally trigger warning
    fs.writeFileSync(path.join(loggingDir, "random-notes.md"), "notes\n");

    process.env["PI_ROLE"] = "shape";

    const stderr = await runHook();
    assert.ok(
      !stderr.includes("WARNING"),
      "expected no WARNING when PI_ROLE=shape (investigative mode)",
    );
  });

  it("still warns when PI_ROLE=build (explicit build role enforces)", async () => {
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    fs.writeFileSync(path.join(loggingDir, "random-notes.md"), "notes\n");

    process.env["PI_ROLE"] = "build";

    const stderr = await runHook();
    assert.ok(
      stderr.includes("WARNING"),
      "expected WARNING when PI_ROLE=build (explicit build role)",
    );
  });

  it("stays observe-only under position-correlation source change (warns, never blocks)", async () => {
    // The Claude source moved to transcript position-correlation; Pi has no
    // transcript and keeps its disk heuristic. This test locks in that the twin
    // still WARNS on a recently-active logging dir with no canonical log, and
    // never returns a block result.
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    fs.writeFileSync(path.join(loggingDir, "random-notes.md"), "notes\n");

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };
    const mod = await import("../step-log-missing-guard");
    mod.register(
      localMockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );

    let stderrOutput = "";
    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (s: string) => {
      stderrOutput += s;
      return true;
    };
    let result: unknown;
    try {
      result = await capturedHandler!({
        toolName: "session_shutdown",
        toolCallId: "test-id",
        input: {},
      });
    } finally {
      process.stderr.write = origWrite;
    }
    assert.ok(
      stderrOutput.includes("step-log-missing-guard"),
      "expected warning on non-canonical-only logging dir",
    );
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
      "Pi session_shutdown must not block",
    );
  });
});
