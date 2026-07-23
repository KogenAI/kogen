/**
 * Tests for claude-debug-bash-guard hook (Pi twin).
 * Mirrors deny/allow cases from claude-debug-bash-guard_test.sh, gated on
 * PI_DEBUG_REMOTE=1 (the pi-debug --server branch) instead of CLAUDE_ROLE.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(command: string) {
  return { toolName: "bash", toolCallId: "test-id", input: { command } };
}

describe("claude-debug-bash-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(command: string, remote = true) {
    const saved = process.env["PI_DEBUG_REMOTE"];
    if (remote) process.env["PI_DEBUG_REMOTE"] = "1";
    else delete process.env["PI_DEBUG_REMOTE"];

    try {
      const { register } = await import("../claude-debug-bash-guard");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      return _capturedHandler(makeToolCallEvent(command));
    } finally {
      if (saved === undefined) delete process.env["PI_DEBUG_REMOTE"];
      else process.env["PI_DEBUG_REMOTE"] = saved;
    }
  }

  beforeEach(() => {
    delete process.env["PI_DEBUG_REMOTE"];
  });

  it("is inactive when PI_DEBUG_REMOTE is unset (local debug has no Bash grant anyway)", async () => {
    const result = await runHook("rm -rf /", false);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks recursive rm when PI_DEBUG_REMOTE=1", async () => {
    const result = await runHook("rm -rf /tmp/x");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks mix ecto.migrate", async () => {
    const result = await runHook("mix ecto.migrate");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks mix ecto.drop", async () => {
    const result = await runHook("mix ecto.drop");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git push", async () => {
    const result = await runHook("git push");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git reset --hard", async () => {
    const result = await runHook("git reset --hard HEAD~1");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks mix deps.get", async () => {
    const result = await runHook("mix deps.get");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks mix run priv/repo/seeds.exs", async () => {
    const result = await runHook("mix run priv/repo/seeds.exs");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks destructive SQL via psql", async () => {
    const result = await runHook("psql -c 'DROP TABLE users'");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks curl -X DELETE", async () => {
    const result = await runHook("curl -X DELETE https://example.com/api");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks docker rm", async () => {
    const result = await runHook("docker rm my-container");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks systemctl restart", async () => {
    const result = await runHook("systemctl restart nginx");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks kill", async () => {
    const result = await runHook("kill 1234");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks npm install", async () => {
    const result = await runHook("npm install -g foo");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows read-only git status", async () => {
    const result = await runHook("git status");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git log", async () => {
    const result = await runHook("git log --oneline -5");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows read-only psql SELECT", async () => {
    const result = await runHook("psql -c 'SELECT * FROM users'");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows grep/ls investigation", async () => {
    const result = await runHook("grep -rn foo lib/");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks nested rm via bash -c wrapper", async () => {
    const result = await runHook("sudo bash -c 'rm -rf /tmp/x'");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("ignores non-bash tools", async () => {
    process.env["PI_DEBUG_REMOTE"] = "1";
    const { register } = await import("../claude-debug-bash-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    const result = await _capturedHandler({
      toolName: "read",
      toolCallId: "x",
      input: { file_path: "foo.txt" },
    });
    delete process.env["PI_DEBUG_REMOTE"];
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
