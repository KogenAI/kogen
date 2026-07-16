/**
 * Tests for orchestrator-no-ci hook.
 * Mirrors cases from orchestrator-no-ci_test.sh.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";

describe("orchestrator-no-ci", { concurrency: false }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    command: string,
    agentType = "",
    agentId = "",
    piRole = "",
    claudeRole = "",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    process.env["AGENT_ID"] = agentId;
    process.env["PI_ROLE"] = piRole;
    process.env["CLAUDE_ROLE"] = claudeRole;

    const { register } = await import("../orchestrator-no-ci");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "bash",
      toolCallId: "test-id",
      input: { command },
    });
  }

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

  // Deny cases — orchestrator level, no bypass
  it("blocks make ci for orchestrator", async () => {
    const result = await runHook("make ci");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks make ci-cover for orchestrator", async () => {
    const result = await runHook("make ci-cover");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks make predeploy for orchestrator", async () => {
    const result = await runHook("make predeploy");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks make llm for orchestrator", async () => {
    const result = await runHook("make llm");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks make llm-phoenix for orchestrator", async () => {
    const result = await runHook("make llm-phoenix");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks make llm-all for orchestrator", async () => {
    const result = await runHook("make llm-all");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks mix coveralls for orchestrator", async () => {
    const result = await runHook("mix coveralls");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks mix test --cover for orchestrator", async () => {
    const result = await runHook("mix test --cover");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks bare mix test for orchestrator", async () => {
    const result = await runHook("mix test");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks mix test with file path (orchestrator must not run tests)", async () => {
    const result = await runHook("mix test test/foo_test.exs");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // Allow cases — gate management
  it("allows make gate-status for orchestrator", async () => {
    const result = await runHook("make gate-status");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows make gate-logs for orchestrator", async () => {
    const result = await runHook("make gate-logs");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows make gate-kill for orchestrator", async () => {
    const result = await runHook("make gate-kill");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Bypass cases — subagent
  it("allows subagent with AGENT_TYPE set", async () => {
    const result = await runHook("make ci", "developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows subagent with AGENT_ID set", async () => {
    const result = await runHook("make ci", "", "some-agent-id");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Bypass cases — ops role
  it("bypasses when PI_ROLE=ops", async () => {
    const result = await runHook("make ci", "", "", "ops");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("bypasses when CLAUDE_ROLE=ops", async () => {
    const result = await runHook("make ci", "", "", "", "ops");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Bypass cases — experiment role
  it("bypasses when PI_ROLE=experiment", async () => {
    const result = await runHook("make ci", "", "", "experiment");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("bypasses when CLAUDE_ROLE=experiment", async () => {
    const result = await runHook("make ci", "", "", "", "experiment");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // Bypass cases — babysit role (drain supervisor dispatching codegen-build)
  it("bypasses when PI_ROLE=babysit", async () => {
    const result = await runHook("make ci", "", "", "babysit");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("bypasses when CLAUDE_ROLE=babysit", async () => {
    const result = await runHook("make ci", "", "", "", "babysit");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows codegen-log write narrating gated phrase", async () => {
    const result = await runHook(
      'codegen-log section --slug test --body @- <<EOF\n## orchestrator Section\nDelegated to developer; make ci ran green in the gate.\nEOF',
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("still blocks real standalone make ci unchanged", async () => {
    const result = await runHook("make ci");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // Non-bash tool passes through
  it("allows non-bash tool (write) for orchestrator", async () => {
    const { register } = await import("../orchestrator-no-ci");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    process.env["AGENT_TYPE"] = "";
    process.env["AGENT_ID"] = "";
    const result = await _capturedHandler({
      toolName: "write",
      toolCallId: "test-id",
      input: { command: "make ci" },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
