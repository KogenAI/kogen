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
      CLAUDE_PROJECT_DIR: process.env["CLAUDE_PROJECT_DIR"],
    };
    delete process.env["AGENT_TYPE"];
    delete process.env["COMMITTER_ALLOW_REVERT"];
    delete process.env["CODEGEN_BUILD_START_TS"];
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
      { CODEGEN_BUILD_START_TS: "1000000" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows when COMMITTER_ALLOW_REVERT=1 (escape hatch)", async () => {
    const result = await runHook("git commit -m test", "committer", {
      CODEGEN_BUILD_START_TS: "1000000",
      COMMITTER_ALLOW_REVERT: "1",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows when CODEGEN_BUILD_START_TS is unset (not a build context)", async () => {
    const result = await runHook("git commit -m test", "committer", {});
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows when command is not git commit (e.g. git status)", async () => {
    const result = await runHook("git status", "committer", {
      CODEGEN_BUILD_START_TS: "1000000",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git commit-graph (word-boundary fix: no substring match on git commit)", async () => {
    const result = await runHook("git commit-graph write", "committer", {
      CODEGEN_BUILD_START_TS: "1000000",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  describe("with a real git repo", () => {
    let tmpDir: string;

    beforeEach(() => {
      tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-revert-test-"));
      gitCmd(tmpDir, ["init", "-q"]);
      gitCmd(tmpDir, ["config", "user.email", "test@example.com"]);
      gitCmd(tmpDir, ["config", "user.name", "Test"]);
      gitCmd(tmpDir, ["config", "core.hooksPath", "/dev/null"]);

      // Baseline commit (pre-session)
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

      // Session commit: update file
      fs.writeFileSync(path.join(tmpDir, "file.txt"), "updated content");
      gitCmd(tmpDir, ["add", "file.txt"]);
      gitCmd(tmpDir, [
        "-c",
        "core.hooksPath=/dev/null",
        "commit",
        "-q",
        "-m",
        "session commit",
      ]);
    });

    afterEach(() => {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    });

    it("allows when no session commits in build window (future build_start)", async () => {
      // Stage forward content
      fs.writeFileSync(path.join(tmpDir, "file.txt"), "new content");
      gitCmd(tmpDir, ["add", "file.txt"]);

      // Build start in the far future — no session commits qualify
      const futureTs = String(Math.floor(Date.now() / 1000) + 3600);
      const result = await runHook("git commit -m forward", "committer", {
        CODEGEN_BUILD_START_TS: futureTs,
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    });

    it("denies when staged content reverts a session commit", async () => {
      // Stage the original (pre-session-commit) content — backward roll
      fs.writeFileSync(path.join(tmpDir, "file.txt"), "original content");
      gitCmd(tmpDir, ["add", "file.txt"]);

      // BUILD_START_TS=0 → all commits qualify as session commits
      const result = await runHook("git commit -m revert", "committer", {
        CODEGEN_BUILD_START_TS: "0",
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok((result as { block?: boolean }).block === true);
    });

    it("allows when staged content is forward progress (not a backward roll)", async () => {
      // Stage new content beyond the session commit
      fs.writeFileSync(
        path.join(tmpDir, "file.txt"),
        "further progress beyond session commit",
      );
      gitCmd(tmpDir, ["add", "file.txt"]);

      const result = await runHook("git commit -m progress", "committer", {
        CODEGEN_BUILD_START_TS: "0",
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    });

    it("allows codegen-log write narrating git commit even with backward-roll content staged", async () => {
      // Stage the original (pre-session-commit) content — would be a backward roll
      fs.writeFileSync(path.join(tmpDir, "file.txt"), "original content");
      gitCmd(tmpDir, ["add", "file.txt"]);

      const result = await runHook(
        'codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git commit -m "msg" successfully.\nEOF',
        "committer",
        {
          CODEGEN_BUILD_START_TS: "0",
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
        CODEGEN_BUILD_START_TS: "0",
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok((result as { block?: boolean }).block === true);
    });
  });
});
