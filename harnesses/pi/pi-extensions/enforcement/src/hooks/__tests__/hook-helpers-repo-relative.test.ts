/**
 * Tests for repoRelative() in lib/hook-helpers.ts.
 * Mirrors the git-toplevel cwd-independence cases in
 * orchestrator-no-source-edit_test.sh (Tests 27b–27d).
 */

import { describe, it, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execFileSync } from "node:child_process";
import { repoRelative } from "../../lib/hook-helpers";

function realp(p: string): string {
  try {
    return fs.realpathSync(p);
  } catch {
    return path.resolve(p);
  }
}

describe("repoRelative git-toplevel resolution", { concurrency: 1 }, () => {
  const created: string[] = [];
  const savedCwd = process.cwd();

  afterEach(() => {
    process.chdir(savedCwd);
    delete process.env["CWD"];
    delete process.env["CLAUDE_PROJECT_DIR"];
    for (const d of created.splice(0)) {
      fs.rmSync(d, { recursive: true, force: true });
    }
  });

  it("strips git toplevel from a sibling cwd (cwd-independent)", () => {
    const repo = realp(fs.mkdtempSync(path.join(os.tmpdir(), "hrr-")));
    created.push(repo);
    execFileSync("git", ["-C", repo, "init", "-q"]);
    fs.mkdirSync(path.join(repo, "codegen/pitches/draft"), { recursive: true });
    fs.mkdirSync(path.join(repo, "test_harness"), { recursive: true });
    // process.cwd() is a sibling subdir, NOT the repo root.
    process.chdir(path.join(repo, "test_harness"));
    delete process.env["CWD"];
    delete process.env["CLAUDE_PROJECT_DIR"];
    const file = path.join(repo, "codegen/pitches/draft/x.md");
    assert.equal(repoRelative(file), "codegen/pitches/draft/x.md");
  });

  it("falls back to launch-cwd strip for a non-repo path", () => {
    const dir = realp(fs.mkdtempSync(path.join(os.tmpdir(), "hrr-norepo-")));
    created.push(dir);
    fs.mkdirSync(path.join(dir, "codegen/pitches/draft"), { recursive: true });
    process.env["CWD"] = dir;
    const file = path.join(dir, "codegen/pitches/draft/x.md");
    assert.equal(repoRelative(file), "codegen/pitches/draft/x.md");
  });

  it("passes relative paths through unchanged", () => {
    assert.equal(
      repoRelative("codegen/pitches/draft/x.md"),
      "codegen/pitches/draft/x.md",
    );
  });
});
