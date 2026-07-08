/**
 * Tests for developer-no-self-gate hook.
 * Mirrors cases from developer-no-self-gate_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execSync } from "node:child_process";

function makeToolCallEvent(
  command: string,
  agentType: string,
  sessionId: string,
) {
  return {
    toolName: "bash",
    toolCallId: "test-id",
    input: { command },
    sessionId,
  };
}

describe("developer-no-self-gate", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    command: string,
    agentType = "developer-phoenix-backend",
    sessionId = "test-session",
    cwd?: string,
  ) {
    process.env["AGENT_TYPE"] = agentType;
    process.env["SESSION_ID"] = sessionId;
    if (cwd) {
      process.env["CWD"] = cwd;
    } else {
      delete process.env["CWD"];
    }
    const { register } = await import("../developer-no-self-gate");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent(command, agentType, sessionId));
  }

  function counterPath(sessionId: string): string {
    return path.join(os.tmpdir(), `codegen-self-gate-${sessionId}.count`);
  }

  function sigPath(sessionId: string): string {
    return path.join(os.tmpdir(), `codegen-self-gate-${sessionId}.sig`);
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["SESSION_ID"];
    delete process.env["CWD"];
    delete process.env["CODEGEN_LOOP"];
  });

  it("passes through for non-developer agent", async () => {
    const sid = `sid1-${Date.now()}`;
    try {
      const result = await runHook(
        "mix test test/foo_test.exs",
        "reviewer-phoenix",
        sid,
      );
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("passes through for non-CI command", async () => {
    const sid = `sid2-${Date.now()}`;
    try {
      const result = await runHook(
        "mix deps.get",
        "developer-phoenix-backend",
        sid,
      );
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("allows 1st CI invocation (count=1)", async () => {
    const sid = `sid3-${Date.now()}`;
    fs.rmSync(counterPath(sid), { force: true });
    try {
      const result = await runHook(
        "mix test test/foo_test.exs",
        "developer-phoenix-backend",
        sid,
      );
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("blocks 3rd CI invocation", async () => {
    const sid = `sid4-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    try {
      const result = await runHook(
        "make ci",
        "developer-phoenix-frontend",
        sid,
      );
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("blocks make ci-fast at count=3", async () => {
    const sid = `sid5-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    try {
      const result = await runHook("make ci-fast", "developer-static", sid);
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("blocks mix credo at count=3", async () => {
    const sid = `sid6-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    try {
      const result = await runHook(
        "mix credo --strict",
        "developer-phoenix-backend",
        sid,
      );
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("blocks developer-static at count=3", async () => {
    const sid = `sid7-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    try {
      const result = await runHook("make test", "developer-static", sid);
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("allows codegen-log write narrating gated phrase without bumping counter", async () => {
    const sid = `sid8-${Date.now()}`;
    fs.rmSync(counterPath(sid), { force: true });
    try {
      const result = await runHook(
        'codegen-log section --slug test --body @- <<EOF\n## developer-phoenix-backend Section\nRan make ci and mix test three times, all green.\nEOF',
        "developer-phoenix-backend",
        sid,
      );
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
      assert.ok(
        !fs.existsSync(counterPath(sid)),
        "codegen-log write must NOT create/increment counter file",
      );
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("still blocks real standalone make ci at count=3 (unchanged)", async () => {
    const sid = `sid9-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    try {
      const result = await runHook("make ci", "developer-phoenix-backend", sid);
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  describe("loop-mode (CODEGEN_LOOP=1): progress-bounded self-verify", () => {
    let loopTmpDir: string;

    beforeEach(() => {
      loopTmpDir = fs.mkdtempSync(
        path.join(os.tmpdir(), "loop-gate-ts-fixture-"),
      );
      execSync("git init -q", { cwd: loopTmpDir });
      execSync('git config user.email "test@example.com"', {
        cwd: loopTmpDir,
      });
      execSync('git config user.name "Test"', { cwd: loopTmpDir });
      execSync("git config commit.gpgsign false", { cwd: loopTmpDir });
      fs.writeFileSync(path.join(loopTmpDir, "a.txt"), "hello");
      execSync("git add a.txt", { cwd: loopTmpDir });
      execSync('git commit -q -m init', { cwd: loopTmpDir });
      process.env["CODEGEN_LOOP"] = "1";
    });

    it("first run in a session is ALLOWED", async () => {
      const sid = `loopsid1-${Date.now()}`;
      fs.rmSync(sigPath(sid), { force: true });
      try {
        const result = await runHook(
          "make test",
          "developer-phoenix-backend",
          sid,
          loopTmpDir,
        );
        assert.ok(
          result == null || (result as { block?: boolean }).block !== true,
        );
        assert.ok(
          fs.existsSync(sigPath(sid)),
          "loop-mode .sig file must be written on first run",
        );
      } finally {
        fs.rmSync(sigPath(sid), { force: true });
        fs.rmSync(loopTmpDir, { recursive: true, force: true });
      }
    });

    it("tree changed since last run → ALLOWED (progress)", async () => {
      const sid = `loopsid2-${Date.now()}`;
      fs.rmSync(sigPath(sid), { force: true });
      try {
        const first = await runHook(
          "make test",
          "developer-phoenix-backend",
          sid,
          loopTmpDir,
        );
        assert.ok(
          first == null || (first as { block?: boolean }).block !== true,
        );

        fs.writeFileSync(path.join(loopTmpDir, "b.txt"), "goodbye");

        const second = await runHook(
          "make test",
          "developer-phoenix-backend",
          sid,
          loopTmpDir,
        );
        assert.ok(
          second == null || (second as { block?: boolean }).block !== true,
        );
      } finally {
        fs.rmSync(sigPath(sid), { force: true });
        fs.rmSync(loopTmpDir, { recursive: true, force: true });
      }
    });

    it("tree UNCHANGED since last run → DENIED (spin)", async () => {
      const sid = `loopsid3-${Date.now()}`;
      fs.rmSync(sigPath(sid), { force: true });
      try {
        const first = await runHook(
          "make test",
          "developer-phoenix-backend",
          sid,
          loopTmpDir,
        );
        assert.ok(
          first == null || (first as { block?: boolean }).block !== true,
        );

        // No edit — same tree, same signature.
        const second = await runHook(
          "make test",
          "developer-phoenix-backend",
          sid,
          loopTmpDir,
        );
        assert.ok((second as { block?: boolean }).block === true);
        assert.match(
          (second as { reason: string }).reason,
          /Make an edit/,
        );
      } finally {
        fs.rmSync(sigPath(sid), { force: true });
        fs.rmSync(loopTmpDir, { recursive: true, force: true });
      }
    });

    it("hard ceiling (15) denies regardless of progress", async () => {
      const sid = `loopsid4-${Date.now()}`;
      // Pre-seed the .sig state file at count=14 (one below the ceiling)
      // with a signature that will not match the next real computed
      // signature (forces the "progress" branch, not the spin branch).
      fs.writeFileSync(sigPath(sid), "bogus-prior-signature\n14\n");
      try {
        const result = await runHook(
          "make test",
          "developer-phoenix-backend",
          sid,
          loopTmpDir,
        );
        assert.ok((result as { block?: boolean }).block === true);
        assert.match(
          (result as { reason: string }).reason,
          /hard ceiling/,
        );
      } finally {
        fs.rmSync(sigPath(sid), { force: true });
        fs.rmSync(loopTmpDir, { recursive: true, force: true });
      }
    });
  });

  it("legacy mode (CODEGEN_LOOP unset) count-of-3 cap unchanged", async () => {
    const sid = `sid10-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    delete process.env["CODEGEN_LOOP"];
    try {
      const result = await runHook("make ci", "developer-phoenix-backend", sid);
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });
});
