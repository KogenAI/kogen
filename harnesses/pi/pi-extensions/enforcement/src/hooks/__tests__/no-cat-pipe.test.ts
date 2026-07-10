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

  it("allows codegen-log write narrating cat pipe", async () => {
    const result = await runHook(
      "bash",
      "codegen-log section --slug test --body @- <<EOF\n## developer-phoenix-backend Section\nUsed Read tool instead of cat foo.txt | head -50 — no truncation.\nEOF",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("still blocks real cat pipe unchanged", async () => {
    const result = await runHook("bash", "cat file.txt | head -20");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── quote-strip fail-closed regression (this pitch) ──────────────────────
  it("allows ssh remote cat-pipe payload (quoted)", async () => {
    const result = await runHook(
      "bash",
      'ssh box "cat /etc/passwd | grep studio"',
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows cat-pipe mentioned in quoted grep arg", async () => {
    const result = await runHook("bash", 'grep -n "cat foo | head" notes.md');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("still blocks real unquoted cat-pipe (fail-closed sanity)", async () => {
    const result = await runHook("bash", "cat notes.md | head -20");
    assert.ok((result as { block?: boolean }).block === true);
  });
});
