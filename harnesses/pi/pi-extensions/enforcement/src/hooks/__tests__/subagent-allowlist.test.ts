/**
 * Tests for subagent-allowlist hook.
 * Mirrors cases from operator-subagent-allowlist.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

describe("subagent-allowlist", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(subagentType: string, piRole = "") {
    process.env["PI_ROLE"] = piRole;
    const { register } = await import("../subagent-allowlist");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "subagent",
      toolCallId: "test-id",
      input: { agent: subagentType },
    });
  }

  beforeEach(() => {
    delete process.env["PI_ROLE"];
  });

  it("allows project subagents (planner-phoenix)", async () => {
    const result = await runHook("planner-phoenix", "build");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows project subagents (developer-phoenix-backend) under build", async () => {
    const result = await runHook("developer-phoenix-backend", "build");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks developer-phoenix-backend under shape role", async () => {
    const result = await runHook("developer-phoenix-backend", "shape");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks reviewer-phoenix under shape role", async () => {
    const result = await runHook("reviewer-phoenix", "shape");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks committer under shape role", async () => {
    const result = await runHook("committer", "shape");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks built-in Plan subagent", async () => {
    const result = await runHook("Plan", "build");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks built-in general-purpose subagent", async () => {
    const result = await runHook("general-purpose", "build");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks built-in statusline-setup subagent", async () => {
    const result = await runHook("statusline-setup", "build");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks empty subagent_type defensively", async () => {
    const result = await runHook("", "build");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows Explore under debug role", async () => {
    const result = await runHook("Explore", "debug");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Explore under shape role", async () => {
    const result = await runHook("Explore", "shape");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks Explore under build role", async () => {
    const result = await runHook("Explore", "build");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("passes through non-subagent tool calls", async () => {
    process.env["PI_ROLE"] = "build";
    const { register } = await import("../subagent-allowlist");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    const result = await _capturedHandler({
      toolName: "bash",
      toolCallId: "test-id",
      input: { command: "echo hello" },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
