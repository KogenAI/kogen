/**
 * Tests for stop-resume hook.
 * Mirrors cases from stop-resume_test.sh.
 * Note: Pi session_shutdown event — cannot emit decision:block directly,
 * but hook may return a block-like object to request re-invocation.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";

function makeStopEvent(
  lastMessage: string,
  sessionId: string,
  stop_hook_active = false,
) {
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

  async function runHook(
    lastMessage: string,
    sessionId: string,
    stop_hook_active = false,
  ) {
    const { register } = await import("../stop-resume");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(
      makeStopEvent(lastMessage, sessionId, stop_hook_active),
    );
  }

  it("401 auth error does not trigger retry", async () => {
    const sid = `sess-t2-${Date.now()}`;
    fs.rmSync(counterPath(sid), { force: true });
    const result = await runHook(
      "API Error: 401 Unauthorized — invalid_api_key",
      sid,
    );
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

  it("transient string yields non-block result (Pi has no counter)", async () => {
    // Pi stop-resume carries no cap/counter; this exercises the transient path
    const sid = `sess-cap-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "3");
    const result = await runHook(
      "Stream idle timeout occurred during response generation",
      sid,
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
    fs.rmSync(counterPath(sid), { force: true });
  });

  async function assertTransientWarns(message: string): Promise<void> {
    process.env["LAST_ASSISTANT_MESSAGE"] = message;
    const originalStderr = process.stderr.write.bind(process.stderr);
    let stderrOutput = "";
    process.stderr.write = (str: unknown) => {
      stderrOutput += str;
      return true;
    };
    try {
      const { register } = await import("../stop-resume");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      await _capturedHandler({ reason: "quit" } as unknown as Parameters<
        typeof _capturedHandler
      >[0]);
      assert.ok(
        stderrOutput.includes("[pi-enforcement:stop-resume]"),
        `expected stop-resume warning in stderr for message "${message}", got: ${stderrOutput}`,
      );
      assert.ok(
        stderrOutput.toLowerCase().includes("transient"),
        `expected 'transient' in stderr warning for message "${message}", got: ${stderrOutput}`,
      );
    } finally {
      process.stderr.write = originalStderr;
      delete process.env["LAST_ASSISTANT_MESSAGE"];
    }
  }

  it("warns on Unable to connect transient error", async () => {
    await assertTransientWarns("Unable to connect to the server");
  });

  it("warns on FailedToOpenSocket transient error", async () => {
    await assertTransientWarns("FailedToOpenSocket: connection refused");
  });

  it("warns on API Error 500 transient error", async () => {
    await assertTransientWarns("API Error: 500 Internal Server Error");
  });

  it("warns on API Error 503 transient error", async () => {
    await assertTransientWarns("API Error: 503 Service Unavailable");
  });

  it("warns on API Error 504 transient error", async () => {
    await assertTransientWarns("API Error: 504 Gateway Timeout");
  });

  it("warns on overloaded_error transient error", async () => {
    await assertTransientWarns("overloaded_error: model is overloaded");
  });

  it("warns on Internal server error transient error", async () => {
    await assertTransientWarns("Internal server error occurred");
  });

  it("warns on upstream connect error transient error", async () => {
    await assertTransientWarns("upstream connect error or disconnect/reset before headers");
  });

  it("warns on socket hang up transient error", async () => {
    await assertTransientWarns("socket hang up during response");
  });

  it("warns on context deadline exceeded transient error", async () => {
    await assertTransientWarns("context deadline exceeded");
  });

  it("warns on modified-since-read transient error", async () => {
    process.env["LAST_ASSISTANT_MESSAGE"] =
      "File has been modified since read — edit conflict";

    const originalStderr = process.stderr.write.bind(process.stderr);
    let stderrOutput = "";
    process.stderr.write = (str: unknown) => {
      stderrOutput += str;
      return true;
    };

    try {
      const { register } = await import("../stop-resume");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      await _capturedHandler({ reason: "quit" } as unknown as Parameters<
        typeof _capturedHandler
      >[0]);
      assert.ok(
        stderrOutput.includes("[pi-enforcement:stop-resume]"),
        `expected stop-resume warning in stderr, got: ${stderrOutput}`,
      );
      assert.ok(
        stderrOutput.toLowerCase().includes("transient"),
        `expected 'transient' in stderr warning, got: ${stderrOutput}`,
      );
    } finally {
      process.stderr.write = originalStderr;
      delete process.env["LAST_ASSISTANT_MESSAGE"];
    }
  });
});
