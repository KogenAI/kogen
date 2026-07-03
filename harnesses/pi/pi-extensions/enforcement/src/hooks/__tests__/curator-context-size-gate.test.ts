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

describe("curator-context-size-gate", { concurrency: false }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  beforeEach(() => {
    process.env["AGENT_TYPE"] = "context-curator";
  });

  afterEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  async function runHook(
    filePath: string,
    toolName = "write",
    agentType = "context-curator",
    extraInput: Record<string, unknown> = {},
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../curator-context-size-gate");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
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

  it("allows non-curator role writing over-cap content (role gate)", async () => {
    const result = await runHook(
      "context/big.md",
      "write",
      "developer-phoenix-backend",
      { content: xString(CAP + 1000) },
    );
    assert.ok(isAllow(result));
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

  it("allows curator multiedit (fail-open: no single old/new pair)", async () => {
    const result = await runHook(
      "context/big.md",
      "multiedit",
      "context-curator",
      { edits: [{ old_string: "a", new_string: xString(CAP + 1000) }] },
    );
    assert.ok(isAllow(result));
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

  it("deny message names context-curator + compress, not committer", async () => {
    const result = await runHook("context/big.md", "write", "context-curator", {
      content: xString(CAP + 1000),
    });
    const reason = (result as { reason: string }).reason;
    assert.ok(/context-curator/i.test(reason));
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
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "pi-ccsg-test-over-"),
    );
    const contextDir = path.join(tmpDir, "context");
    fs.mkdirSync(contextDir, { recursive: true });
    const filePath = path.join(contextDir, "existing.md");
    fs.writeFileSync(filePath, xString(40000));

    try {
      const result = await runHook(filePath, "edit", "context-curator", {
        old_string: "0123456789",
        new_string: "y".repeat(5000),
      });
      assert.ok(isDeny(result));
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("allows curator edit projecting under cap (real on-disk fixture)", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "pi-ccsg-test-under-"),
    );
    const contextDir = path.join(tmpDir, "context");
    fs.mkdirSync(contextDir, { recursive: true });
    const filePath = path.join(contextDir, "existing.md");
    fs.writeFileSync(filePath, xString(100));

    try {
      const result = await runHook(filePath, "edit", "context-curator", {
        old_string: "0123456789",
        new_string: "y".repeat(20),
      });
      assert.ok(isAllow(result));
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
