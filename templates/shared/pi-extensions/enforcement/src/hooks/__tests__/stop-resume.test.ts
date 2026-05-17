/**
 * Tests for stop-resume hook.
 * Mirrors cases from stop-resume_test.sh.
 * Note: Pi session_shutdown event — cannot emit decision:block directly,
 * but hook may return a block-like object to request re-invocation.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";

function makeStopEvent(lastMessage: string, sessionId: string, stop_hook_active = false) {
  return {
    toolName: "session_shutdown",
    toolCallId: "test-id",
    input: { last_assistant_message: lastMessage, stop_hook_active },
    sessionId,
  };
}

function counterPath(sessionId: string): string {
  return `/tmp/claude-resume-${sessionId}.count`;
}

describe("stop-resume", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(lastMessage: string, sessionId: string, stop_hook_active = false) {
    const { register } = await import("../stop-resume");
    register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
    return _capturedHandler(makeStopEvent(lastMessage, sessionId, stop_hook_active));
  }

  it("401 auth error does not trigger retry", async () => {
    const sid = `sess-t2-${Date.now()}`;
    fs.rmSync(counterPath(sid), { force: true });
    const result = await runHook("API Error: 401 Unauthorized — invalid_api_key", sid);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    fs.rmSync(counterPath(sid), { force: true });
  });

  it("429 rate limit does not trigger retry", async () => {
    const sid = `sess-t3-${Date.now()}`;
    fs.rmSync(counterPath(sid), { force: true });
    const result = await runHook("API Error: 429 rate_limit exceeded", sid);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    fs.rmSync(counterPath(sid), { force: true });
  });

  it("normal stop (no error) does not trigger retry", async () => {
    const sid = `sess-t4-${Date.now()}`;
    fs.rmSync(counterPath(sid), { force: true });
    const result = await runHook("Task complete.", sid);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    fs.rmSync(counterPath(sid), { force: true });
  });

  it("stop_hook_active=true exits without retry (loop guard)", async () => {
    const sid = `sess-loop-${Date.now()}`;
    fs.rmSync(counterPath(sid), { force: true });
    const result = await runHook("Stream idle timeout occurred", sid, true);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    fs.rmSync(counterPath(sid), { force: true });
  });

  it("retry cap reached (count=3) — no retry on 4th attempt", async () => {
    const sid = `sess-cap-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "3");
    const result = await runHook("Stream idle timeout occurred during response generation", sid);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    fs.rmSync(counterPath(sid), { force: true });
  });
});
