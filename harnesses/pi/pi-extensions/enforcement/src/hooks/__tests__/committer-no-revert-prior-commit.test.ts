/**
 * Tests for committer-no-revert-prior-commit hook.
 * Mirrors cases from committer-no-revert-prior-commit_test.sh.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { execFileSync } from "node:child_process";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

function gitCmd(cwd: string, args: string[]): void {
  execFileSync("git", args, {
    cwd,
    stdio: "pipe",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "Test",
      GIT_AUTHOR_EMAIL: "test@example.com",
      GIT_COMMITTER_NAME: "Test",
      GIT_COMMITTER_EMAIL: "test@example.com",
    },
  });
}

function gitRevParseHead(cwd: string): string {
  return execFileSync("git", ["rev-parse", "HEAD"], {
    cwd,
    encoding: "utf8",
  }).trim();
}

describe("committer-no-revert-prior-commit", { concurrency: 1 }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  let savedEnv: Record<string, string | undefined>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    command: string,
    agentType = "committer",
    extraEnv: Record<string, string> = {},
  ) {
    process.env["AGENT_TYPE"] = agentType;
    for (const [k, v] of Object.entries(extraEnv)) {
      process.env[k] = v;
    }
    const { register } = await import("../committer-no-revert-prior-commit");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent("bash", command));
  }

  beforeEach(() => {
    savedEnv = {
      AGENT_TYPE: process.env["AGENT_TYPE"],
      COMMITTER_ALLOW_REVERT: process.env["COMMITTER_ALLOW_REVERT"],
      CODEGEN_BUILD_START_TS: process.env["CODEGEN_BUILD_START_TS"],
      CODEGEN_CYCLE_BASE_SHA: process.env["CODEGEN_CYCLE_BASE_SHA"],
      CLAUDE_PROJECT_DIR: process.env["CLAUDE_PROJECT_DIR"],
    };
    delete process.env["AGENT_TYPE"];
    delete process.env["COMMITTER_ALLOW_REVERT"];
    delete process.env["CODEGEN_BUILD_START_TS"];
    delete process.env["CODEGEN_CYCLE_BASE_SHA"];
    delete process.env["CLAUDE_PROJECT_DIR"];
  });

  afterEach(() => {
    for (const [k, v] of Object.entries(savedEnv)) {
      if (v === undefined) {
        delete process.env[k];
      } else {
        process.env[k] = v;
      }
    }
  });

  it("passes through for non-committer agent", async () => {
    const result = await runHook(
      "git commit -m test",
      "developer-phoenix-backend",
      { CODEGEN_CYCLE_BASE_SHA: "deadbeef" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows when COMMITTER_ALLOW_REVERT=1 (escape hatch)", async () => {
    const result = await runHook("git commit -m test", "committer", {
      CODEGEN_CYCLE_BASE_SHA: "deadbeef",
      COMMITTER_ALLOW_REVERT: "1",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows when CODEGEN_CYCLE_BASE_SHA is unset (not a build context)", async () => {
    const result = await runHook("git commit -m test", "committer", {});
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows when command is not git commit (e.g. git status)", async () => {
    const result = await runHook("git status", "committer", {
      CODEGEN_CYCLE_BASE_SHA: "deadbeef",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git commit-graph (word-boundary fix: no substring match on git commit)", async () => {
    const result = await runHook("git commit-graph write", "committer", {
      CODEGEN_CYCLE_BASE_SHA: "deadbeef",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  describe("with a real git repo", () => {
    let tmpDir: string;
    let baseSha: string;

    beforeEach(() => {
      tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-revert-test-"));
      gitCmd(tmpDir, ["init", "-q"]);
      gitCmd(tmpDir, ["config", "user.email", "test@example.com"]);
      gitCmd(tmpDir, ["config", "user.name", "Test"]);
      gitCmd(tmpDir, ["config", "core.hooksPath", "/dev/null"]);

      // Baseline commit (pre-cycle — this is CODEGEN_CYCLE_BASE_SHA)
      fs.writeFileSync(path.join(tmpDir, "file.txt"), "original content");
      gitCmd(tmpDir, ["add", "file.txt"]);
      gitCmd(tmpDir, [
        "-c",
        "core.hooksPath=/dev/null",
        "commit",
        "-q",
        "-m",
        "baseline",
      ]);
      baseSha = gitRevParseHead(tmpDir);

      // Cycle commit: update file
      fs.writeFileSync(path.join(tmpDir, "file.txt"), "updated content");
      gitCmd(tmpDir, ["add", "file.txt"]);
      gitCmd(tmpDir, [
        "-c",
        "core.hooksPath=/dev/null",
        "commit",
        "-q",
        "-m",
        "cycle commit",
      ]);
    });

    afterEach(() => {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    });

    it("allows when no cycle commits exist (base == HEAD)", async () => {
      // Stage forward content
      fs.writeFileSync(path.join(tmpDir, "file.txt"), "new content");
      gitCmd(tmpDir, ["add", "file.txt"]);

      const headSha = gitRevParseHead(tmpDir);
      const result = await runHook("git commit -m forward", "committer", {
        CODEGEN_CYCLE_BASE_SHA: headSha,
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    });

    it("denies when staged content reverts a cycle commit", async () => {
      // Stage the original (pre-cycle-commit) content — backward roll
      fs.writeFileSync(path.join(tmpDir, "file.txt"), "original content");
      gitCmd(tmpDir, ["add", "file.txt"]);

      const result = await runHook("git commit -m revert", "committer", {
        CODEGEN_CYCLE_BASE_SHA: baseSha,
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok((result as { block?: boolean }).block === true);
    });

    it("allows when staged content is forward progress (not a backward roll)", async () => {
      // Stage new content beyond the cycle commit
      fs.writeFileSync(
        path.join(tmpDir, "file.txt"),
        "further progress beyond cycle commit",
      );
      gitCmd(tmpDir, ["add", "file.txt"]);

      const result = await runHook("git commit -m progress", "committer", {
        CODEGEN_CYCLE_BASE_SHA: baseSha,
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    });

    it("allows codegen-log write narrating git commit even with backward-roll content staged", async () => {
      // Stage the original (pre-cycle-commit) content — would be a backward roll
      fs.writeFileSync(path.join(tmpDir, "file.txt"), "original content");
      gitCmd(tmpDir, ["add", "file.txt"]);

      const result = await runHook(
        'codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git commit -m "msg" successfully.\nEOF',
        "committer",
        {
          CODEGEN_CYCLE_BASE_SHA: baseSha,
          CLAUDE_PROJECT_DIR: tmpDir,
        },
      );
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    });

    it("still denies real staged backward-roll commit unchanged", async () => {
      fs.writeFileSync(path.join(tmpDir, "file.txt"), "original content");
      gitCmd(tmpDir, ["add", "file.txt"]);

      const result = await runHook("git commit -m revert", "committer", {
        CODEGEN_CYCLE_BASE_SHA: baseSha,
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok((result as { block?: boolean }).block === true);
    });
  });

  describe("earlier-role commit (cycle-stable base)", () => {
    let tmpDir: string;
    let cycleBase: string;

    beforeEach(() => {
      tmpDir = fs.mkdtempSync(
        path.join(os.tmpdir(), "pi-revert-earlier-role-test-"),
      );
      gitCmd(tmpDir, ["init", "-q"]);
      gitCmd(tmpDir, ["config", "user.email", "test@example.com"]);
      gitCmd(tmpDir, ["config", "user.name", "Test"]);
      gitCmd(tmpDir, ["config", "core.hooksPath", "/dev/null"]);

      fs.writeFileSync(path.join(tmpDir, "file.txt"), "original");
      gitCmd(tmpDir, ["add", "file.txt"]);
      gitCmd(tmpDir, [
        "-c",
        "core.hooksPath=/dev/null",
        "commit",
        "-q",
        "-m",
        "cycle base commit",
      ]);
      cycleBase = gitRevParseHead(tmpDir);

      // Simulate an EARLIER role committing before the committer's own turn.
      fs.writeFileSync(
        path.join(tmpDir, "file.txt"),
        "changed by an earlier role",
      );
      gitCmd(tmpDir, ["add", "file.txt"]);
      gitCmd(tmpDir, [
        "-c",
        "core.hooksPath=/dev/null",
        "commit",
        "-q",
        "-m",
        "earlier-role commit",
      ]);
    });

    afterEach(() => {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    });

    it("denies backward roll against an earlier role's commit via cycle-stable base", async () => {
      // committer stages a backward roll against the earlier role's commit
      fs.writeFileSync(path.join(tmpDir, "file.txt"), "original");
      gitCmd(tmpDir, ["add", "file.txt"]);

      const result = await runHook("git commit -m revert", "committer", {
        CODEGEN_CYCLE_BASE_SHA: cycleBase,
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok((result as { block?: boolean }).block === true);
    });
  });
});
