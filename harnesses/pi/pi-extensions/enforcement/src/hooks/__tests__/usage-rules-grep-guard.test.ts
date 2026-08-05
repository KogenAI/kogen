/**
 * Tests for usage-rules-grep-guard hook.
 * Mirrors cases from usage-rules-grep-guard_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, input: Record<string, string>) {
  return { toolName, toolCallId: "test-id", input };
}

describe("usage-rules-grep-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function register() {
    const { register: reg } = await import("../usage-rules-grep-guard");
    reg(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
  }

  it("blocks reviewer-phoenix grep usage_rules via bash", async () => {
    process.env["AGENT_TYPE"] = "reviewer-phoenix";
    await register();
    const result = await _capturedHandler(
      makeToolCallEvent("bash", {
        command: "grep foo codegen/usage_rules/oban.md",
      }),
    );
    assert.ok((result as { block?: boolean }).block === true);
    delete process.env["AGENT_TYPE"];
  });

  it("blocks context-curator grep usage_rules via bash", async () => {
    process.env["AGENT_TYPE"] = "context-curator";
    await register();
    const result = await _capturedHandler(
      makeToolCallEvent("bash", {
        command: "grep foo codegen/usage_rules/oban.md",
      }),
    );
    assert.ok((result as { block?: boolean }).block === true);
    delete process.env["AGENT_TYPE"];
  });

  // Real role names carry a stack suffix; a bare "developer" never fires in
  // production — these fixtures exercise the actual developer-* match, the
  // same shape the bash twin asserts.
  it("allows developer-phoenix-backend grep usage_rules via bash", async () => {
    process.env["AGENT_TYPE"] = "developer-phoenix-backend";
    await register();
    const result = await _capturedHandler(
      makeToolCallEvent("bash", {
        command: "grep foo codegen/usage_rules/oban.md",
      }),
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("allows developer-static grep usage_rules via bash", async () => {
    process.env["AGENT_TYPE"] = "developer-static";
    await register();
    const result = await _capturedHandler(
      makeToolCallEvent("bash", {
        command: "grep foo codegen/usage_rules/oban.md",
      }),
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("allows reviewer-phoenix grep codegen/recipes/", async () => {
    process.env["AGENT_TYPE"] = "reviewer-phoenix";
    await register();
    const result = await _capturedHandler(
      makeToolCallEvent("bash", {
        command: "grep foo codegen/recipes/INDEX.md",
      }),
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });

  it("blocks reviewer-phoenix Grep tool on usage_rules path", async () => {
    process.env["AGENT_TYPE"] = "reviewer-phoenix";
    await register();
    const result = await _capturedHandler(
      makeToolCallEvent("grep", {
        pattern: "foo",
        path: "codegen/usage_rules/oban.md",
      }),
    );
    assert.ok((result as { block?: boolean }).block === true);
    delete process.env["AGENT_TYPE"];
  });

  it("allows developer-phoenix-backend Grep tool on usage_rules path", async () => {
    process.env["AGENT_TYPE"] = "developer-phoenix-backend";
    await register();
    const result = await _capturedHandler(
      makeToolCallEvent("grep", {
        pattern: "foo",
        path: "codegen/usage_rules/oban.md",
      }),
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    delete process.env["AGENT_TYPE"];
  });
});
