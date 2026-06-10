/**
 * Tests for context-curator-guard hook.
 * Mirrors cases from context-curator-guard_test.sh.
 * Uses relative paths for file_path (same convention as committer-write-allowlist tests).
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";

describe("context-curator-guard", { concurrency: false }, () => {
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
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../context-curator-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName,
      toolCallId: "test-id",
      input: { file_path: filePath },
    });
  }

  it("allows non-curator agent unconditionally", async () => {
    const result = await runHook(
      "lib/foo.ex",
      "write",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows curator writing to context/**", async () => {
    const result = await runHook("context/foo.md");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows curator writing to codegen/rules/**", async () => {
    const result = await runHook("codegen/rules/some-rule.md");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows curator writing to codegen/logging/**", async () => {
    const result = await runHook(
      "codegen/logging/20260601_120000_session.md",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies curator writing to lib/foo.ex", async () => {
    const result = await runHook("lib/foo.ex");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("denies curator writing to shared/rules/foo.md (not codegen/rules/)", async () => {
    const result = await runHook("shared/rules/foo.md");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows empty file_path (fail-open)", async () => {
    const result = await runHook("");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows non-write/edit tool (bash) for curator", async () => {
    const result = await runHook("lib/foo.ex", "bash");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows curator using edit tool to context/", async () => {
    const result = await runHook("context/dev.md", "edit");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("denies curator using edit tool outside allowed surface", async () => {
    const result = await runHook("priv/repo/migrations/001.exs", "edit");
    assert.ok((result as { block?: boolean }).block === true);
  });
});
