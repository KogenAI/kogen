/**
 * Tests for no-cat-pipe hook.
 * Mirrors cases from no-cat-pipe_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("no-cat-pipe", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(toolName: string, command: string) {
    const { register } = await import("../no-cat-pipe");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent(toolName, command));
  }

  it("blocks cat file | head", async () => {
    const result = await runHook("bash", "cat file.txt | head -20");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks cat file | tail", async () => {
    const result = await runHook("bash", "cat file.txt | tail -10");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks cat file | grep", async () => {
    const result = await runHook("bash", "cat file.txt | grep pattern");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows cat file.txt (no pipe)", async () => {
    const result = await runHook("bash", "cat file.txt");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows echo x | cat", async () => {
    const result = await runHook("bash", "echo x | cat");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows non-bash tool", async () => {
    const result = await runHook("read", "cat file.txt | head");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
