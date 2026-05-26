/**
 * Tests for developer-no-self-gate-reset hook.
 * Mirrors cases from developer-no-self-gate-reset_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

function makeSessionShutdownEvent(agentType: string, sessionId: string) {
  return {
    toolName: "session_shutdown",
    toolCallId: "test-id",
    input: {},
    sessionId,
    agentType,
  };
}

describe("developer-no-self-gate-reset", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(agentType: string, sessionId: string) {
    process.env["AGENT_TYPE"] = agentType;
    process.env["SESSION_ID"] = sessionId;
    const { register } = await import("../developer-no-self-gate-reset");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeSessionShutdownEvent(agentType, sessionId));
  }

  function counterPath(sessionId: string): string {
    return path.join(os.tmpdir(), `combobulate-self-gate-${sessionId}.count`);
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["SESSION_ID"];
  });

  it("developer-phoenix-backend removes counter file", async () => {
    const sid = `reset-test-1-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    await runHook("developer-phoenix-backend", sid);
    assert.ok(!fs.existsSync(counterPath(sid)));
  });

  it("developer-phoenix-frontend removes counter file", async () => {
    const sid = `reset-test-2-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "1");
    await runHook("developer-phoenix-frontend", sid);
    assert.ok(!fs.existsSync(counterPath(sid)));
  });

  it("developer-html removes counter file", async () => {
    const sid = `reset-test-3-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "3");
    await runHook("developer-html", sid);
    assert.ok(!fs.existsSync(counterPath(sid)));
  });

  it("non-developer agent does not remove counter file", async () => {
    const sid = `reset-test-4-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    try {
      await runHook("reviewer-phoenix", sid);
      assert.ok(fs.existsSync(counterPath(sid)));
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("no counter file exits cleanly", async () => {
    const sid = `reset-test-5-${Date.now()}`;
    fs.rmSync(counterPath(sid), { force: true });
    // should not throw
    await runHook("developer-vite", sid);
    assert.ok(true);
  });

  it("developer-hugo removes counter file", async () => {
    const sid = `reset-test-6-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "1");
    await runHook("developer-hugo", sid);
    assert.ok(!fs.existsSync(counterPath(sid)));
  });
});
