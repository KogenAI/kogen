/**
 * Tests for pre-commit-guard hook.
 * Mirrors cases from pre-commit-guard_test.sh.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execSync } from "node:child_process";
import { stripGitGlobalOpts } from "../../lib/hook-helpers";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("pre-commit-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  const tmpRepos: string[] = [];

  function makeRepoWithCommit(commitTs: number): string {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pre-commit-guard-test-"));
    tmpRepos.push(tmpDir);
    execSync("git init -q", { cwd: tmpDir });
    execSync("git config user.email test@example.com", { cwd: tmpDir });
    execSync("git config user.name Test", { cwd: tmpDir });
    execSync("git config commit.gpgsign false", { cwd: tmpDir });
    fs.writeFileSync(path.join(tmpDir, "baseline.txt"), "baseline\n");
    execSync("git add baseline.txt", { cwd: tmpDir });
    const iso = new Date(commitTs * 1000).toISOString();
    execSync("git -c core.hooksPath=/dev/null commit -q -m baseline", {
      cwd: tmpDir,
      env: {
        ...process.env,
        GIT_AUTHOR_DATE: iso,
        GIT_COMMITTER_DATE: iso,
      },
    });
    return tmpDir;
  }


  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(toolName: string, command: string, agentType = "") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../pre-commit-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent(toolName, command));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["CWD"];
    delete process.env["CODEGEN_BUILD_START_TS"];
  });

  afterEach(() => {
    for (const repo of tmpRepos.splice(0)) {
      fs.rmSync(repo, { recursive: true, force: true });
    }
  });

  it("blocks git commit for developer agent", async () => {
    const result = await runHook(
      "bash",
      "git commit -m 'fix'",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git status for developer agent", async () => {
    const result = await runHook(
      "bash",
      "git status",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git commit for committer", async () => {
    const result = await runHook("bash", "git commit -m 'fix'", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks git rebase for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git rebase -i HEAD~2",
      "developer-phoenix-frontend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git push --force for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git push origin main --force",
      "planner-phoenix",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git reset --hard for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git reset --hard HEAD~1",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git reset for a prior-cycle commit", async () => {
    const repo = makeRepoWithCommit(1700000000);
    process.env["CWD"] = repo;
    process.env["CODEGEN_BUILD_START_TS"] = "1700000100";
    const result = await runHook(
      "bash",
      "git reset HEAD~1",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git reset for this-cycle commit", async () => {
    const repo = makeRepoWithCommit(1700000200);
    process.env["CWD"] = repo;
    process.env["CODEGEN_BUILD_START_TS"] = "1700000100";
    const result = await runHook(
      "bash",
      "git reset HEAD~1",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks for orchestrator (empty agent_type)", async () => {
    const result = await runHook("bash", "git commit -m 'fix'", "");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git add -A for developer agent", async () => {
    const result = await runHook(
      "bash",
      "git add -A",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows git add -A for committer", async () => {
    const result = await runHook("bash", "git add -A", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("no longer blocks git stash directly (no-git-stash.ts owns it; arm removed as redundant)", async () => {
    const result = await runHook(
      "bash",
      "git stash",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git commit-graph (word-boundary fix: no substring match on git commit)", async () => {
    const result = await runHook(
      "bash",
      "git commit-graph write",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("leg D: denies git restore foo (no --staged) for non-committer (flip)", async () => {
    const result = await runHook(
      "bash",
      "git restore foo",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git restore --staged foo for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git restore --staged foo",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("leg D: denies git checkout -- <path> for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git checkout -- foo.ex",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("leg D: denies git switch for non-committer", async () => {
    const result = await runHook("bash", "git switch main", "developer-phoenix-backend");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("leg D: denies git clean -fd for non-committer", async () => {
    const result = await runHook("bash", "git clean -fd", "developer-phoenix-backend");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("leg D: allows git clean -n (dry-run) for non-committer", async () => {
    const result = await runHook("bash", "git clean -n", "developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("leg D: denies git reset --merge for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git reset --merge HEAD~1",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("leg D: denies git reset --keep for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git reset --keep HEAD~1",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("leg D: git checkout still allowed for committer", async () => {
    const result = await runHook("bash", "git checkout -- foo.ex", "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("leg D: git show HEAD:<path> allowed for non-committer (substitute)", async () => {
    const result = await runHook(
      "bash",
      "git show HEAD:lib/foo.ex",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── codegen-log carve-out: piped body prose containing git-verb tokens ──
  // Every role's session-log section body is piped into codegen-log. The
  // piped body is arbitrary role-authored prose that may legitimately
  // describe a git operation. This must ALLOW for a non-committer role
  // because the codegen-log carve-out exits before the git-verb scans run.
  // Bare history-mutating git commands remain denied.

  it("allows non-committer codegen-log body with 'git commit' prose (carve-out)", async () => {
    const result = await runHook(
      "bash",
      'printf %s "Verified git commit -m done" | codegen-log section --body @-',
      "reviewer-phoenix",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks non-committer bare git commit (no codegen-log)", async () => {
    const result = await runHook(
      "bash",
      'git commit -m "x"',
      "reviewer-phoenix",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  // Test 24b (this pitch): the crossed cell — codegen-log TOKEN present AND
  // a REAL, chained git commit. isCodegenLogWrite requires exactly ONE
  // hard-boundary group, so a real codegen-log call && a real commit is
  // correctly NOT exempt — MUST DENY.
  it("blocks non-committer codegen-log token present + chained real commit (crossed cell)", async () => {
    const result = await runHook(
      "bash",
      "codegen-log append developer --slug foo && git commit -m x",
      "reviewer-phoenix",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── quote-strip fail-closed regression (this pitch) ──────────────────────
  it("allows ssh remote git-stash payload (quoted) for non-committer", async () => {
    const result = await runHook(
      "bash",
      'ssh box "git stash"',
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git add mentioned in quoted grep arg", async () => {
    const result = await runHook(
      "bash",
      'grep -n "git add" notes.md',
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("still blocks real unquoted git rebase (fail-closed sanity)", async () => {
    const result = await runHook(
      "bash",
      "git rebase --continue",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("still blocks git commit with quoted -m arg (verb unquoted)", async () => {
    const result = await runHook(
      "bash",
      "git commit -m 'quoted message'",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── git global-option evasion regression (this pitch) ──────────────────
  // git's global options (-C <path>, --git-dir=, -c k=v, --no-pager, ...)
  // may sit between `git` and its subcommand. Every verb regex assumed
  // `git` was immediately followed by the verb token — `git -C /tmp/x
  // commit -m y` evaded the match entirely. stripGitGlobalOpts() normalizes
  // these before matching.

  it("blocks git -C <dir> commit for non-committer (global-opt evasion closed)", async () => {
    const result = await runHook(
      "bash",
      "git -C /tmp/x commit -m y",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git --git-dir=<x> add for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git --git-dir=/tmp/x/.git add -A",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git -c k=v rm for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git -c user.name=x rm foo",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git -C <dir> push --force for non-committer", async () => {
    const result = await runHook(
      "bash",
      "git -C /tmp/x push --force origin main",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("still allows git -C <dir> commit for committer (actor gate unaffected)", async () => {
    const result = await runHook(
      "bash",
      "git -C /tmp/x commit -m y",
      "committer",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("still allows git -C <dir> status for non-committer (read-only unaffected)", async () => {
    const result = await runHook(
      "bash",
      "git -C /tmp/x status",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── indirection expansion: bash <file> body-scan (a-guard-on-a-verb) ────
  // A guard on a verb is a guard on spelling: `bash /tmp/x.sh` carries no
  // forbidden verb in the command STRING itself; only the referenced file's
  // BODY does. expandCommandIndirection() closes this for the two
  // hand-authored guards.

  it("denies bash <file with git reset --hard body> for non-committer (indirection)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pre-commit-guard-indirect-"));
    tmpRepos.push(tmpDir);
    const scriptPath = path.join(tmpDir, "danger.sh");
    fs.writeFileSync(scriptPath, "git reset --hard HEAD~1\n");
    const result = await runHook(
      "bash",
      `bash ${scriptPath}`,
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows bash <file with benign body> for non-committer (no regression)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pre-commit-guard-indirect-"));
    tmpRepos.push(tmpDir);
    const scriptPath = path.join(tmpDir, "benign.sh");
    fs.writeFileSync(scriptPath, "echo hello world\n");
    const result = await runHook(
      "bash",
      `bash ${scriptPath}`,
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it('allows bash "$dynamic" (unresolvable path) for non-committer (no regression)', async () => {
    const result = await runHook(
      "bash",
      'bash "$dynamic"',
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies source <file with git reset --hard body> for non-committer (indirection, source form)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pre-commit-guard-indirect-"));
    tmpRepos.push(tmpDir);
    const scriptPath = path.join(tmpDir, "danger.sh");
    fs.writeFileSync(scriptPath, "git reset --hard HEAD~1\n");
    const result = await runHook(
      "bash",
      `source ${scriptPath}`,
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("still allows bash <file with git reset --hard body> for committer (actor gate unaffected)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pre-commit-guard-indirect-"));
    tmpRepos.push(tmpDir);
    const scriptPath = path.join(tmpDir, "danger.sh");
    fs.writeFileSync(scriptPath, "git reset --hard HEAD~1\n");
    const result = await runHook("bash", `bash ${scriptPath}`, "committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});

describe("stripGitGlobalOpts", () => {
  it("normalizes -C <path> before the verb", () => {
    assert.equal(
      stripGitGlobalOpts("git -C /tmp/x commit -m y"),
      "git commit -m y",
    );
  });

  it("normalizes --git-dir=<x> (inline)", () => {
    assert.equal(
      stripGitGlobalOpts("git --git-dir=/x add foo"),
      "git add foo",
    );
  });

  it("normalizes --git-dir <x> (separate token)", () => {
    assert.equal(
      stripGitGlobalOpts("git --git-dir /x add foo"),
      "git add foo",
    );
  });

  it("normalizes -c k=v before the verb", () => {
    assert.equal(
      stripGitGlobalOpts("git -c user.name=x commit -m y"),
      "git commit -m y",
    );
  });

  it("normalizes --no-pager before the verb", () => {
    assert.equal(stripGitGlobalOpts("git --no-pager log"), "git log");
  });

  it("normalizes multiple stacked global options", () => {
    assert.equal(
      stripGitGlobalOpts("git -C /x -c user.name=y --no-pager commit -m y"),
      "git commit -m y",
    );
  });

  it("leaves a plain git commit unchanged", () => {
    assert.equal(stripGitGlobalOpts("git commit -m y"), "git commit -m y");
  });

  it("leaves non-git input unchanged", () => {
    assert.equal(stripGitGlobalOpts("echo hi && ls"), "echo hi && ls");
  });

  it("normalizes the git segment inside a chained command", () => {
    assert.equal(
      stripGitGlobalOpts("foo && git -C x commit -m y && bar"),
      "foo && git commit -m y && bar",
    );
  });

  it("never consumes the verb itself", () => {
    assert.equal(stripGitGlobalOpts("git -C /tmp/x status"), "git status");
  });
});
