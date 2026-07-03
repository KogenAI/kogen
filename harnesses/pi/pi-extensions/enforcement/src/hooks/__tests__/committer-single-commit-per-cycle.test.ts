/**
 * Tests for committer-single-commit-per-cycle hook.
 * Mirrors cases from committer-single-commit-per-cycle_test.sh.
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

describe("committer-single-commit-per-cycle", { concurrency: 1 }, () => {
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
    const { register } = await import(
      "../committer-single-commit-per-cycle"
    );
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent("bash", command));
  }

  beforeEach(() => {
    savedEnv = {
      AGENT_TYPE: process.env["AGENT_TYPE"],
      COMMITTER_ALLOW_MULTI: process.env["COMMITTER_ALLOW_MULTI"],
      CODEGEN_BUILD_START_TS: process.env["CODEGEN_BUILD_START_TS"],
      CLAUDE_PROJECT_DIR: process.env["CLAUDE_PROJECT_DIR"],
    };
    delete process.env["AGENT_TYPE"];
    delete process.env["COMMITTER_ALLOW_MULTI"];
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

  it("allows when COMMITTER_ALLOW_MULTI=1 (escape hatch)", async () => {
    const result = await runHook("git commit -m test", "committer", {
      CODEGEN_BUILD_START_TS: "0",
      COMMITTER_ALLOW_MULTI: "1",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows when CODEGEN_BUILD_START_TS is unset", async () => {
    const result = await runHook("git commit -m test", "committer", {});
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows when command is not git commit", async () => {
    const result = await runHook("git status", "committer", {
      CODEGEN_BUILD_START_TS: "1000000",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  describe("with a real git repo", () => {
    let tmpDir: string;

    beforeEach(() => {
      tmpDir = fs.mkdtempSync(
        path.join(os.tmpdir(), "pi-single-commit-test-"),
      );
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

      // Session commit
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

    it("allows --amend even when session commit exists", async () => {
      const result = await runHook(
        "git commit --amend -m test",
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

    it("allows first commit (no session commits in build window)", async () => {
      // Build start in the far future — no session commits qualify
      const futureTs = String(Math.floor(Date.now() / 1000) + 3600);
      const result = await runHook("git commit -m first", "committer", {
        CODEGEN_BUILD_START_TS: futureTs,
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    });

    it("denies second non-amend commit when session commit already exists", async () => {
      // BUILD_START_TS=0 → the session commit qualifies, so this is a second commit
      const result = await runHook("git commit -m second", "committer", {
        CODEGEN_BUILD_START_TS: "0",
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok((result as { block?: boolean }).block === true);
    });

    it("denies --amend when HEAD predates cycle start (foreign amend)", async () => {
      // Set cycle start 1 hour in the future so HEAD commit time < cycle start
      const futureStartTs = String(Math.floor(Date.now() / 1000) + 3600);
      const result = await runHook("git commit --amend -m test", "committer", {
        CODEGEN_BUILD_START_TS: futureStartTs,
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok((result as { block?: boolean }).block === true);
    });

    it("allows codegen-log write narrating git commit even with session commit present", async () => {
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

    it("still denies real standalone second commit unchanged", async () => {
      const result = await runHook("git commit -m second", "committer", {
        CODEGEN_BUILD_START_TS: "0",
        CLAUDE_PROJECT_DIR: tmpDir,
      });
      assert.ok((result as { block?: boolean }).block === true);
    });
  });
});
