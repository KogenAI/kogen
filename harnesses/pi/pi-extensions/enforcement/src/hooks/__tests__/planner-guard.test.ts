/**
 * Tests for planner-guard hook.
 * Mirrors cases from planner-guard_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, input: Record<string, string>) {
  return { toolName, toolCallId: "test-id", input };
}

describe("planner-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    toolName: string,
    input: Record<string, string>,
    agentType: string,
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../planner-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent(toolName, input));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("blocks Write for planner-phoenix", async () => {
    const result = await runHook(
      "write",
      { file_path: "/tmp/foo.ex", content: "x" },
      "planner-phoenix",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows Write for developer-phoenix-backend", async () => {
    const result = await runHook(
      "write",
      { file_path: "/tmp/foo.ex", content: "x" },
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows planner-static bash with 2>&1 pipe", async () => {
    const result = await runHook(
      "bash",
      { command: "grep foo lib/bar.ex 2>&1 | head" },
      "planner-static",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks planner-static make ci-fast", async () => {
    const result = await runHook(
      "bash",
      { command: "make ci-fast" },
      "planner-static",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks planner-static make llm-summary", async () => {
    const result = await runHook(
      "bash",
      { command: "make llm-summary" },
      "planner-static",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks planner-phoenix make llm-kill", async () => {
    const result = await runHook(
      "bash",
      { command: "make llm-kill" },
      "planner-phoenix",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks planner-phoenix make llm-retry", async () => {
    const result = await runHook(
      "bash",
      { command: "make llm-retry" },
      "planner-phoenix",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks planner-phoenix mv to /etc/passwd", async () => {
    const result = await runHook(
      "bash",
      { command: "mv /tmp/a /etc/passwd" },
      "planner-phoenix",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows planner-phoenix mv within /tmp/", async () => {
    const result = await runHook(
      "bash",
      { command: "mv /tmp/a /tmp/b" },
      "planner-phoenix",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows planner-phoenix Edit on codegen/logging/", async () => {
    const result = await runHook(
      "edit",
      {
        file_path: "codegen/logging/session.md",
        old_string: "x",
        new_string: "## planner Section\ny",
      },
      "planner-phoenix",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── codegen-log carve-out: piped body prose containing trigger tokens ──
  // The plan body is written via `printf '%s' "$body" | codegen-log section
  // --body @-`. The piped body is arbitrary plan prose that may legitimately
  // contain gate tokens, git verbs, or redirect chars. These must ALLOW
  // because the codegen-log carve-out exits before the broad scans run.

  it("allows planner-phoenix codegen-log body with 'make ci' prose (carve-out)", async () => {
    const result = await runHook(
      "bash",
      { command: 'printf %s "Gate: make ci passed after fix" | codegen-log section --body @-' },
      "planner-phoenix",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows planner-static codegen-log body with 'git commit' prose (carve-out)", async () => {
    const result = await runHook(
      "bash",
      {
        command:
          'printf %s "Plan: git commit -m done after review" | codegen-log section --body @-',
      },
      "planner-static",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows planner-phoenix codegen-log body with redirect char prose (carve-out)", async () => {
    const result = await runHook(
      "bash",
      {
        command:
          'printf %s "cmd > /etc/output for reference" | codegen-log section --body @-',
      },
      "planner-phoenix",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks planner-phoenix bare make ci (no codegen-log)", async () => {
    const result = await runHook("bash", { command: "make ci" }, "planner-phoenix");
    assert.ok((result as { block?: boolean }).block === true);
  });
});
