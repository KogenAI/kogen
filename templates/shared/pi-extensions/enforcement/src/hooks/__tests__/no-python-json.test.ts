/**
 * Tests for no-python-json hook.
 * Mirrors cases from no-python-json_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, command: string) {
  return { toolName, toolCallId: "test-id", input: { command } };
}

describe("no-python-json", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(toolName: string, command: string) {
    const { register } = await import("../no-python-json");
    register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
    return _capturedHandler(makeToolCallEvent(toolName, command));
  }

  it("blocks python3 -c with import json", async () => {
    const result = await runHook("bash", "python3 -c 'import json; data = json.load(open(\"f\"))'");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks python -c with json.load", async () => {
    const result = await runHook("bash", "python -c \"import json; print(json.load(open('x')))\"");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows python3 script.py", async () => {
    const result = await runHook("bash", "python3 script.py");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows python3 -c 'print(1)'", async () => {
    const result = await runHook("bash", "python3 -c 'print(1)'");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows non-bash tool", async () => {
    const result = await runHook("read", "python3 -c 'import json'");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
