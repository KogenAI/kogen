/**
 * Tests for getActiveStepLog() in lib/hook-helpers.ts.
 *
 * Covers: .active sentinel precedence (native full-fidelity resolution for
 * Pi — a synchronous disk read, no transcript-flush race), stale-sentinel
 * fallback to mtime scan, and the no-sentinel mtime-scan-only path already
 * covered indirectly by consumer-hook tests but asserted here directly
 * against the shared helper.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { getActiveStepLog } from "../../lib/hook-helpers";

describe("getActiveStepLog", () => {
  const created: string[] = [];

  // getActiveStepLog()'s resolution step 0 reads process.env.CODEGEN_LOG_PATH
  // FIRST, ahead of the .active sentinel / mtime scan every test below is
  // actually exercising. Under a real loop-mode session this env var is
  // ambiently set to the CURRENT cycle's own log — if it leaks into this
  // suite unmuted, every assertion here silently gets overridden by that
  // ambient pin instead of the fixture path under test. Save/restore at
  // suite (beforeEach/afterEach) scope, not per-test-body, since ALL tests
  // in this file are equally exposed (none of them intend to test the pin
  // itself — that is the dedicated "CODEGEN_LOG_PATH pin wins" test below,
  // which manages the var itself at body scope per existing convention).
  let savedCodegenLogPath: string | undefined;

  beforeEach(() => {
    savedCodegenLogPath = process.env.CODEGEN_LOG_PATH;
    delete process.env.CODEGEN_LOG_PATH;
  });

  afterEach(() => {
    if (savedCodegenLogPath === undefined) {
      delete process.env.CODEGEN_LOG_PATH;
    } else {
      process.env.CODEGEN_LOG_PATH = savedCodegenLogPath;
    }
    for (const d of created.splice(0)) {
      fs.rmSync(d, { recursive: true, force: true });
    }
  });

  function makeProjectDir(): string {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gasl-"));
    created.push(dir);
    fs.mkdirSync(path.join(dir, "codegen", "logging"), { recursive: true });
    return dir;
  }

  it("returns null when codegen/logging/ does not exist", () => {
    const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "gasl-nodir-"));
    created.push(projectDir);
    assert.equal(getActiveStepLog(projectDir), null);
  });

  it("returns null when logging dir is empty (no sentinel, no logs)", () => {
    const projectDir = makeProjectDir();
    assert.equal(getActiveStepLog(projectDir), null);
  });

  it("resolves via .active sentinel when it points at an existing file", () => {
    const projectDir = makeProjectDir();
    const loggingDir = path.join(projectDir, "codegen", "logging");
    const target = path.join(loggingDir, "20260101_120000_foo_cycle.jsonl");
    fs.writeFileSync(target, "## Version Stamp\n");
    // A second, newer file exists on disk but must NOT win — the sentinel
    // takes precedence over mtime.
    const newer = path.join(loggingDir, "20260101_130000_bar_cycle.jsonl");
    fs.writeFileSync(newer, "## Version Stamp\n");
    fs.writeFileSync(path.join(loggingDir, ".active"), target);

    assert.equal(getActiveStepLog(projectDir), target);
  });

  it("falls back to mtime scan when .active points at a deleted file (stale sentinel)", () => {
    const projectDir = makeProjectDir();
    const loggingDir = path.join(projectDir, "codegen", "logging");
    const stale = path.join(loggingDir, "20260101_120000_gone_cycle.jsonl");
    // Never created on disk — simulates a relocated/deleted log.
    const survivor = path.join(loggingDir, "20260101_130000_still_cycle.jsonl");
    fs.writeFileSync(survivor, "## Version Stamp\n");
    fs.writeFileSync(path.join(loggingDir, ".active"), stale);

    assert.equal(getActiveStepLog(projectDir), survivor);
  });

  it("falls back to mtime scan when no .active sentinel is present", () => {
    const projectDir = makeProjectDir();
    const loggingDir = path.join(projectDir, "codegen", "logging");
    const older = path.join(loggingDir, "20260101_120000_older_cycle.jsonl");
    fs.writeFileSync(older, "## Version Stamp\n");
    // Ensure a distinct, later mtime for the "newer" file.
    const newer = path.join(loggingDir, "20260101_130000_newer_cycle.jsonl");
    fs.writeFileSync(newer, "## Version Stamp\n");
    const now = Date.now();
    fs.utimesSync(older, new Date(now - 10_000), new Date(now - 10_000));
    fs.utimesSync(newer, new Date(now), new Date(now));

    assert.equal(getActiveStepLog(projectDir), newer);
  });

  it("excludes progress files from the mtime-scan fallback", () => {
    const projectDir = makeProjectDir();
    const loggingDir = path.join(projectDir, "codegen", "logging");
    const progress = path.join(loggingDir, "20260101_130000_progress.jsonl");
    fs.writeFileSync(progress, "progress\n");
    const real = path.join(loggingDir, "20260101_120000_real_cycle.jsonl");
    fs.writeFileSync(real, "## Version Stamp\n");

    assert.equal(getActiveStepLog(projectDir), real);
  });

  it("ignores an empty .active sentinel file (falls back to mtime scan)", () => {
    const projectDir = makeProjectDir();
    const loggingDir = path.join(projectDir, "codegen", "logging");
    const real = path.join(loggingDir, "20260101_120000_real_cycle.jsonl");
    fs.writeFileSync(real, "## Version Stamp\n");
    fs.writeFileSync(path.join(loggingDir, ".active"), "");

    assert.equal(getActiveStepLog(projectDir), real);
  });

  // CODEGEN_LOG_PATH pin — resolution step 0. Save/restore process.env at
  // test-body scope (not describe-level before/afterEach) so a failure in
  // one case can never bleed the pin into a sibling test.
  it("CODEGEN_LOG_PATH pin wins over a hijacked .active sentinel pointing at a different, existing log", () => {
    const projectDir = makeProjectDir();
    const loggingDir = path.join(projectDir, "codegen", "logging");
    const pinned = path.join(
      loggingDir,
      "20260714_182153_pinned-real_cycle.jsonl",
    );
    const hijacked = path.join(
      loggingDir,
      "20260714_182357_hijacked-rival_cycle.jsonl",
    );
    fs.writeFileSync(pinned, "## Version Stamp\n");
    fs.writeFileSync(hijacked, "## Version Stamp\n");
    fs.writeFileSync(path.join(loggingDir, ".active"), hijacked);

    const saved = process.env.CODEGEN_LOG_PATH;
    try {
      process.env.CODEGEN_LOG_PATH = pinned;
      assert.equal(getActiveStepLog(projectDir), pinned);
    } finally {
      if (saved === undefined) delete process.env.CODEGEN_LOG_PATH;
      else process.env.CODEGEN_LOG_PATH = saved;
    }
  });

  it("dangling CODEGEN_LOG_PATH pin (set but file missing) falls through to .active", () => {
    const projectDir = makeProjectDir();
    const loggingDir = path.join(projectDir, "codegen", "logging");
    const activeTarget = path.join(
      loggingDir,
      "20260714_000000_active-fallback_cycle.jsonl",
    );
    fs.writeFileSync(activeTarget, "## Version Stamp\n");
    fs.writeFileSync(path.join(loggingDir, ".active"), activeTarget);

    const saved = process.env.CODEGEN_LOG_PATH;
    try {
      process.env.CODEGEN_LOG_PATH = path.join(
        loggingDir,
        "does-not-exist_cycle.jsonl",
      );
      assert.equal(getActiveStepLog(projectDir), activeTarget);
    } finally {
      if (saved === undefined) delete process.env.CODEGEN_LOG_PATH;
      else process.env.CODEGEN_LOG_PATH = saved;
    }
  });

  it("no CODEGEN_LOG_PATH set → unaffected, .active still wins as before", () => {
    const projectDir = makeProjectDir();
    const loggingDir = path.join(projectDir, "codegen", "logging");
    const target = path.join(loggingDir, "20260714_000001_no-pin_cycle.jsonl");
    fs.writeFileSync(target, "## Version Stamp\n");
    fs.writeFileSync(path.join(loggingDir, ".active"), target);

    const saved = process.env.CODEGEN_LOG_PATH;
    try {
      delete process.env.CODEGEN_LOG_PATH;
      assert.equal(getActiveStepLog(projectDir), target);
    } finally {
      if (saved === undefined) delete process.env.CODEGEN_LOG_PATH;
      else process.env.CODEGEN_LOG_PATH = saved;
    }
  });
});
