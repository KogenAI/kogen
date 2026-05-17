/**
 * Tests for step-log-completeness hook.
 * Mirrors cases from step-log-completeness_test.sh.
 * Note: Pi session_shutdown event — cannot block. Hook warns via stderr only.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

describe("step-log-completeness", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(stop_hook_active = false, cwd = "/tmp") {
    const { register } = await import("../step-log-completeness");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "session_shutdown",
      toolCallId: "test-id",
      input: { cwd, stop_hook_active },
    });
  }

  it("stop_hook_active=true short-circuits without crash", async () => {
    const result = await runHook(true);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("no log found exits cleanly (no block)", async () => {
    const result = await runHook(false, "/tmp/no-such-dir-for-step-log-test");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("normal shutdown does not crash", async () => {
    const result = await runHook(false, "/tmp");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
