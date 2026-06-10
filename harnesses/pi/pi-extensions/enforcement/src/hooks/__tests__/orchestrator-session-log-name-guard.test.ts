/**
 * Tests for orchestrator-session-log-name-guard hook.
 * Mirrors cases from orchestrator-session-log-name-guard_test.sh.
 * Uses relative paths for file_path (same convention as committer-write-allowlist tests).
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";

describe("orchestrator-session-log-name-guard", { concurrency: false }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["AGENT_ID"];
    delete process.env["PI_ROLE"];
    delete process.env["CLAUDE_ROLE"];
  });

  afterEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["AGENT_ID"];
    delete process.env["PI_ROLE"];
    delete process.env["CLAUDE_ROLE"];
  });

  async function runHook(
    filePath: string,
    toolName = "write",
    agentType = "",
    agentId = "",
    piRole = "",
    claudeRole = "",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    process.env["AGENT_ID"] = agentId;
    process.env["PI_ROLE"] = piRole;
    process.env["CLAUDE_ROLE"] = claudeRole;

    const { register } = await import(
      "../orchestrator-session-log-name-guard"
    );
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName,
      toolCallId: "test-id",
      input: { file_path: filePath },
    });
  }

  // Allow: canonical names — relative paths
  it("allows canonical session log YYYYMMDD_HHMMSS_session.md", async () => {
    const result = await runHook(
      "codegen/logging/20260601_120000_session.md",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows canonical session log with slug", async () => {
    const result = await runHook(
      "codegen/logging/20260601_120000_my-feature_session.md",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows canonical step log", async () => {
    const result = await runHook(
      "codegen/logging/20260601_120000_step1_my-feature.md",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows progress log YYYYMMDD_progress.md", async () => {
    const result = await runHook(
      "codegen/logging/20260601_progress.md",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Deny: non-canonical names in codegen/logging/
  it("denies non-canonical name in codegen/logging/", async () => {
    const result = await runHook("codegen/logging/badname.md");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("denies date-only name without time", async () => {
    const result = await runHook("codegen/logging/20260601_session.md");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // Allow: non-logging path passes through
  it("allows write to lib/foo.ex (non-logging path)", async () => {
    const result = await runHook("lib/foo.ex");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Allow: subagent passes through
  it("allows subagent with AGENT_TYPE set", async () => {
    const result = await runHook(
      "codegen/logging/badname.md",
      "write",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows subagent with AGENT_ID set", async () => {
    const result = await runHook(
      "codegen/logging/badname.md",
      "write",
      "",
      "some-agent-id",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Allow: ops bypass
  it("bypasses when PI_ROLE=ops", async () => {
    const result = await runHook(
      "codegen/logging/badname.md",
      "write",
      "",
      "",
      "ops",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("bypasses when CLAUDE_ROLE=ops", async () => {
    const result = await runHook(
      "codegen/logging/badname.md",
      "write",
      "",
      "",
      "",
      "ops",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Allow: non-write/edit tool
  it("allows non-write tool (bash) for orchestrator", async () => {
    const { register } = await import("../orchestrator-session-log-name-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    const result = await _capturedHandler({
      toolName: "bash",
      toolCallId: "test-id",
      input: { file_path: "codegen/logging/badname.md" },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
