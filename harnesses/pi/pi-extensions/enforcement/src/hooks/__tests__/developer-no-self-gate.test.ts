/**
 * Tests for developer-no-self-gate hook.
 * Mirrors cases from developer-no-self-gate_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

function makeToolCallEvent(
  command: string,
  agentType: string,
  sessionId: string,
) {
  return {
    toolName: "bash",
    toolCallId: "test-id",
    input: { command },
    sessionId,
  };
}

describe("developer-no-self-gate", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    command: string,
    agentType = "developer-phoenix-backend",
    sessionId = "test-session",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    process.env["SESSION_ID"] = sessionId;
    const { register } = await import("../developer-no-self-gate");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeToolCallEvent(command, agentType, sessionId));
  }

  function counterPath(sessionId: string): string {
    return path.join(os.tmpdir(), `codegen-self-gate-${sessionId}.count`);
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["SESSION_ID"];
  });

  it("passes through for non-developer agent", async () => {
    const sid = `sid1-${Date.now()}`;
    try {
      const result = await runHook(
        "mix test test/foo_test.exs",
        "reviewer-phoenix",
        sid,
      );
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("passes through for non-CI command", async () => {
    const sid = `sid2-${Date.now()}`;
    try {
      const result = await runHook(
        "mix deps.get",
        "developer-phoenix-backend",
        sid,
      );
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("allows 1st CI invocation (count=1)", async () => {
    const sid = `sid3-${Date.now()}`;
    fs.rmSync(counterPath(sid), { force: true });
    try {
      const result = await runHook(
        "mix test test/foo_test.exs",
        "developer-phoenix-backend",
        sid,
      );
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("blocks 3rd CI invocation", async () => {
    const sid = `sid4-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    try {
      const result = await runHook(
        "make ci",
        "developer-phoenix-frontend",
        sid,
      );
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("blocks make ci-fast at count=3", async () => {
    const sid = `sid5-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    try {
      const result = await runHook("make ci-fast", "developer-static", sid);
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("blocks mix credo at count=3", async () => {
    const sid = `sid6-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    try {
      const result = await runHook(
        "mix credo --strict",
        "developer-phoenix-backend",
        sid,
      );
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });

  it("blocks developer-static at count=3", async () => {
    const sid = `sid7-${Date.now()}`;
    fs.writeFileSync(counterPath(sid), "2");
    try {
      const result = await runHook("make test", "developer-static", sid);
      assert.ok((result as { block?: boolean }).block === true);
    } finally {
      fs.rmSync(counterPath(sid), { force: true });
    }
  });
});
