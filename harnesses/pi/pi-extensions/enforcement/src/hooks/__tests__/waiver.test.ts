/**
 * Tests for isWaived() in hooks/_waiver.ts.
 * Mirrors the six cases in _waiver_test.sh.
 */

import { describe, it, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execFileSync } from "node:child_process";
import { isWaived } from "../_waiver";

function realp(p: string): string {
  try {
    return fs.realpathSync(p);
  } catch {
    return path.resolve(p);
  }
}

const REGISTRY_FIXTURE = `- kind: registration
  id: prompt-budget-writer-only
  event: PreToolUse
  tool_guard: "Bash|Edit|Write|MultiEdit"
  surface: user_global
  signal: AGENT_TYPE
  role: "*"
  harnesses: all
  waivable: true
  rationale: fixture entry

- kind: registration
  id: session-log-writer-only
  event: PreToolUse
  tool_guard: "Bash|Edit|Write|MultiEdit"
  surface: user_global
  signal: AGENT_TYPE
  role: "*"
  harnesses: all
`;

describe("isWaived", { concurrency: 1 }, () => {
  const created: string[] = [];
  const savedCwd = process.cwd();
  const savedPath = process.env["PATH"];

  afterEach(() => {
    process.chdir(savedCwd);
    delete process.env["CODEGEN_WAIVED_GUARDS"];
    delete process.env["PI_ROLE"];
    delete process.env["CLAUDE_ROLE"];
    if (savedPath !== undefined) process.env["PATH"] = savedPath;
    for (const d of created.splice(0)) {
      fs.rmSync(d, { recursive: true, force: true });
    }
  });

  function makeRepo(): string {
    const repo = realp(fs.mkdtempSync(path.join(os.tmpdir(), "waiver-")));
    created.push(repo);
    execFileSync("git", ["-C", repo, "init", "-q"]);
    fs.mkdirSync(path.join(repo, "shared/enforcement"), { recursive: true });
    fs.mkdirSync(path.join(repo, "codegen/pitches/building"), {
      recursive: true,
    });
    fs.writeFileSync(
      path.join(repo, "shared/enforcement/registry.yaml"),
      REGISTRY_FIXTURE,
    );

    // Stub codegen-log on PATH so recordWaiver's execFileSync succeeds
    // without a real binary.
    const stubBin = path.join(repo, "stubbin");
    fs.mkdirSync(stubBin, { recursive: true });
    const stubPath = path.join(stubBin, "codegen-log");
    fs.writeFileSync(stubPath, "#!/bin/bash\nexit 0\n");
    fs.chmodSync(stubPath, 0o755);
    process.env["PATH"] = `${stubBin}:${savedPath ?? ""}`;

    process.chdir(repo);
    return repo;
  }

  function writePitch(repo: string, slug: string, waivesLine: string): void {
    const buildingDir = path.join(repo, "codegen/pitches/building");
    fs.rmSync(buildingDir, { recursive: true, force: true });
    fs.mkdirSync(buildingDir, { recursive: true });
    const lines = ["---", "status: ready"];
    if (waivesLine) lines.push(waivesLine);
    lines.push("---", `# ${slug}`);
    fs.writeFileSync(
      path.join(buildingDir, `${slug}.md`),
      lines.join("\n") + "\n",
    );
  }

  function clearPitches(repo: string): void {
    const buildingDir = path.join(repo, "codegen/pitches/building");
    fs.rmSync(buildingDir, { recursive: true, force: true });
    fs.mkdirSync(buildingDir, { recursive: true });
  }

  it("env + file both name id -> waived true", () => {
    const repo = makeRepo();
    writePitch(repo, "wtest1", "waives: [prompt-budget-writer-only]");
    process.env["CODEGEN_WAIVED_GUARDS"] = "prompt-budget-writer-only";
    assert.equal(isWaived("prompt-budget-writer-only"), true);
  });

  it("env only, file omits it -> deny", () => {
    const repo = makeRepo();
    writePitch(repo, "wtest2", "");
    process.env["CODEGEN_WAIVED_GUARDS"] = "prompt-budget-writer-only";
    assert.equal(isWaived("prompt-budget-writer-only"), false);
  });

  it("file only, env unset -> deny", () => {
    const repo = makeRepo();
    writePitch(repo, "wtest3", "waives: [prompt-budget-writer-only]");
    delete process.env["CODEGEN_WAIVED_GUARDS"];
    assert.equal(isWaived("prompt-budget-writer-only"), false);
  });

  it("neither env nor file -> deny", () => {
    const repo = makeRepo();
    clearPitches(repo);
    delete process.env["CODEGEN_WAIVED_GUARDS"];
    assert.equal(isWaived("prompt-budget-writer-only"), false);
  });

  it("malformed waives line -> deny", () => {
    const repo = makeRepo();
    writePitch(repo, "wtest4", "waives: not-a-list-([{");
    process.env["CODEGEN_WAIVED_GUARDS"] = "prompt-budget-writer-only";
    assert.equal(isWaived("prompt-budget-writer-only"), false);
  });

  it("non-waivable registry entry -> deny even with env+file", () => {
    const repo = makeRepo();
    writePitch(repo, "wtest5", "waives: [session-log-writer-only]");
    process.env["CODEGEN_WAIVED_GUARDS"] = "session-log-writer-only";
    assert.equal(isWaived("session-log-writer-only"), false);
  });

  it("zero files in building/ -> deny", () => {
    const repo = makeRepo();
    clearPitches(repo);
    process.env["CODEGEN_WAIVED_GUARDS"] = "prompt-budget-writer-only";
    assert.equal(isWaived("prompt-budget-writer-only"), false);
  });

  it("2+ files in building/ -> deny", () => {
    const repo = makeRepo();
    writePitch(repo, "wtest6a", "waives: [prompt-budget-writer-only]");
    fs.writeFileSync(
      path.join(repo, "codegen/pitches/building/wtest6b.md"),
      ["---", "status: ready", "waives: [prompt-budget-writer-only]", "---", "# wtest6b"].join(
        "\n",
      ) + "\n",
    );
    process.env["CODEGEN_WAIVED_GUARDS"] = "prompt-budget-writer-only";
    assert.equal(isWaived("prompt-budget-writer-only"), false);
  });
});
