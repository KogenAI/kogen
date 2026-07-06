/**
 * Tests for getActiveStepLog() in lib/hook-helpers.ts.
 *
 * Covers: .active sentinel precedence (native full-fidelity resolution for
 * Pi — a synchronous disk read, no transcript-flush race), stale-sentinel
 * fallback to mtime scan, and the no-sentinel mtime-scan-only path already
 * covered indirectly by consumer-hook tests but asserted here directly
 * against the shared helper.
 */

import { describe, it, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { getActiveStepLog } from "../../lib/hook-helpers";

describe("getActiveStepLog", () => {
  const created: string[] = [];

  afterEach(() => {
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
});
