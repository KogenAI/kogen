/**
 * Tests for curator-context-size-gate hook.
 * Mirrors surface-level cases from curator-context-size-gate_test.sh.
 * Deep git-state / boundary-byte cases are covered by the bash twin.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execFileSync } from "node:child_process";

describe("curator-context-size-gate", { concurrency: false }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  let repoDir: string;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  beforeEach(() => {
    repoDir = fs.mkdtempSync(path.join(os.tmpdir(), "curator-size-gate-pi-"));
    fs.mkdirSync(path.join(repoDir, "context"), { recursive: true });
    fs.mkdirSync(path.join(repoDir, "context", "sub"), { recursive: true });
    fs.mkdirSync(path.join(repoDir, "lib"), { recursive: true });
    fs.mkdirSync(path.join(repoDir, "codegen"), { recursive: true });
    execFileSync("git", ["init", "-q"], { cwd: repoDir });
    process.env["CWD"] = repoDir;
    process.env["AGENT_TYPE"] = "context-curator";
  });

  afterEach(() => {
    delete process.env["CWD"];
    delete process.env["AGENT_TYPE"];
    fs.rmSync(repoDir, { recursive: true, force: true });
  });

  async function runHook(
    relFilePath: string,
    toolName = "write",
    agentType = "context-curator",
    extraInput: Record<string, unknown> = {},
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../curator-context-size-gate");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    const filePath = relFilePath === "" ? "" : path.join(repoDir, relFilePath);
    return _capturedHandler({
      toolName,
      toolCallId: "test-id",
      input: { file_path: filePath, ...extraInput },
    });
  }

  const isAllow = (r: unknown): boolean =>
    r == null || (r as { block?: boolean }).block !== true;
  const isDeny = (r: unknown): boolean =>
    (r as { block?: boolean }).block === true;

  const CAP = 40960;
  const xString = (n: number): string => "x".repeat(n);

  it("denies non-curator role writing over-cap content (role-agnostic)", async () => {
    const result = await runHook(
      "context/big.md",
      "write",
      "developer-phoenix-backend",
      { content: xString(CAP + 1000) },
    );
    assert.ok(isDeny(result));
  });

  it("allows curator bash tool with over-cap-shaped payload (tool gate)", async () => {
    const result = await runHook(
      "context/big.md",
      "bash",
      "context-curator",
      { command: "echo hi", content: xString(CAP + 1000) },
    );
    assert.ok(isAllow(result));
  });

  it("allows curator write to non-context path (path gate)", async () => {
    const result = await runHook("lib/foo.ex", "write", "context-curator", {
      content: xString(CAP + 1000),
    });
    assert.ok(isAllow(result));
  });

  it("allows curator write to context/sub/nested.md (subdir excluded)", async () => {
    const result = await runHook(
      "context/sub/nested.md",
      "write",
      "context-curator",
      { content: xString(CAP + 1000) },
    );
    assert.ok(isAllow(result));
  });

  it("denies curator multiedit summing edits[] deltas over cap", async () => {
    const result = await runHook(
      "context/big.md",
      "multiedit",
      "context-curator",
      { edits: [{ old_string: "a", new_string: xString(CAP + 1000) }] },
    );
    assert.ok(isDeny(result));
  });

  it("allows curator multiedit with no edits (fail-open)", async () => {
    const result = await runHook(
      "context/big.md",
      "multiedit",
      "context-curator",
      { edits: [] },
    );
    assert.ok(isAllow(result));
  });

  it("denies non-curator multiedit summing edits[] deltas over cap (role-agnostic)", async () => {
    const result = await runHook(
      "context/big.md",
      "multiedit",
      "developer-phoenix-backend",
      { edits: [{ old_string: "a", new_string: xString(CAP + 1000) }] },
    );
    assert.ok(isDeny(result));
  });

  it("allows curator write with missing content field (fail-open)", async () => {
    const result = await runHook("context/big.md", "write", "context-curator");
    assert.ok(isAllow(result));
  });

  it("allows empty file_path (fail-open)", async () => {
    const result = await runHook("", "write", "context-curator", {
      content: xString(CAP + 1000),
    });
    assert.ok(isAllow(result));
  });

  it("allows curator write with small content", async () => {
    const result = await runHook("context/ok.md", "write", "context-curator", {
      content: "small content",
    });
    assert.ok(isAllow(result));
  });

  it("denies curator write with content over cap", async () => {
    const result = await runHook("context/big.md", "write", "context-curator", {
      content: xString(CAP + 1000),
    });
    assert.ok(isDeny(result));
  });

  it("deny message names compress, not committer", async () => {
    const result = await runHook("context/big.md", "write", "context-curator", {
      content: xString(CAP + 1000),
    });
    const reason = (result as { reason: string }).reason;
    assert.ok(/compress/i.test(reason));
    assert.ok(!/committer/i.test(reason));
  });

  it("deny message contains projected byte count and cap substring", async () => {
    const contentLen = CAP + 1000;
    const result = await runHook("context/big.md", "write", "context-curator", {
      content: xString(contentLen),
    });
    const reason = (result as { reason: string }).reason;
    assert.ok(reason.includes(String(contentLen)));
    assert.ok(reason.includes("40960-byte (40k) cap"));
  });

  it("denies curator edit projecting over cap (real on-disk fixture)", async () => {
    const filePath = path.join(repoDir, "context", "existing.md");
    fs.writeFileSync(filePath, xString(40000));

    const result = await runHook("context/existing.md", "edit", "context-curator", {
      old_string: "0123456789",
      new_string: "y".repeat(5000),
    });
    assert.ok(isDeny(result));
  });

  it("allows curator edit projecting under cap (real on-disk fixture)", async () => {
    const filePath = path.join(repoDir, "context", "existing.md");
    fs.writeFileSync(filePath, xString(100));

    const result = await runHook("context/existing.md", "edit", "context-curator", {
      old_string: "0123456789",
      new_string: "y".repeat(20),
    });
    assert.ok(isAllow(result));
  });

  it("denies curator write to PROJECT_CONTEXT.md over cap (root doc)", async () => {
    const result = await runHook(
      "PROJECT_CONTEXT.md",
      "write",
      "context-curator",
      { content: xString(CAP + 1000) },
    );
    assert.ok(isDeny(result));
  });

  it("denies curator write to codegen/PROJECT_CONTEXT.md over cap (root doc variant)", async () => {
    const result = await runHook(
      "codegen/PROJECT_CONTEXT.md",
      "write",
      "context-curator",
      { content: xString(CAP + 1000) },
    );
    assert.ok(isDeny(result));
  });

  it("allows curator write to PROJECT_CONTEXT.md under cap", async () => {
    const result = await runHook(
      "PROJECT_CONTEXT.md",
      "write",
      "context-curator",
      { content: "small content" },
    );
    assert.ok(isAllow(result));
  });

  it("allows write outside a git repo (fail-open)", async () => {
    const noGitDir = fs.mkdtempSync(path.join(os.tmpdir(), "curator-size-gate-nogit-"));
    process.env["CWD"] = noGitDir;
    try {
      const result = await runHook(
        "PROJECT_CONTEXT.md",
        "write",
        "context-curator",
        { content: xString(CAP + 1000) },
      );
      assert.ok(isAllow(result));
    } finally {
      fs.rmSync(noGitDir, { recursive: true, force: true });
    }
  });

  it("allows CLAUDE.md over cap (deliberately not gated)", async () => {
    const result = await runHook("CLAUDE.md", "write", "context-curator", {
      content: xString(CAP + 1000),
    });
    assert.ok(isAllow(result));
  });

  it("root-doc deny message does not tell writer to add a PROJECT_CONTEXT.md row", async () => {
    const result = await runHook(
      "PROJECT_CONTEXT.md",
      "write",
      "context-curator",
      { content: xString(CAP + 1000) },
    );
    const reason = (result as { reason: string }).reason;
    assert.ok(!reason.includes("add the matching PROJECT_CONTEXT.md"));
  });
});
