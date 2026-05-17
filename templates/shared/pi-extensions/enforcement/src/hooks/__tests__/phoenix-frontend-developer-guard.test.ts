/**
 * Tests for phoenix-frontend-developer-guard hook.
 * Mirrors cases from phoenix-frontend-developer-guard_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

describe("phoenix-frontend-developer-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHookEdit(
    filePath: string,
    agentType = "developer-phoenix-frontend",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../phoenix-frontend-developer-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "edit",
      toolCallId: "test-id",
      input: { file_path: filePath },
    });
  }

  async function runHookRead(
    filePath: string,
    agentType = "developer-phoenix-frontend",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../phoenix-frontend-developer-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "read",
      toolCallId: "test-id",
      input: { file_path: filePath },
    });
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("blocks Edit on migration path", async () => {
    const result = await runHookEdit(
      "/app/priv/repo/migrations/20240101_create_users.exs",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks Edit on lib/app/contexts/", async () => {
    const result = await runHookEdit("/app/lib/my_app/contexts/accounts.ex");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks Edit on lib/app/services/", async () => {
    const result = await runHookEdit(
      "/app/lib/my_app/services/email_service.ex",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks Edit on lib/app/workers/", async () => {
    const result = await runHookEdit(
      "/app/lib/my_app/workers/digest_worker.ex",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks Edit on lib/my_app/ (non-_web backend)", async () => {
    const result = await runHookEdit("/app/lib/my_app/accounts/user.ex");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows Edit on lib/my_app_web/", async () => {
    const result = await runHookEdit("/app/lib/my_app_web/live/user_live.ex");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Edit on assets/js/", async () => {
    const result = await runHookEdit("/app/assets/js/app.js");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Edit on migration by backend agent (not gated)", async () => {
    const result = await runHookEdit(
      "/app/priv/repo/migrations/20240101_create_users.exs",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Read on migration (not gated tool)", async () => {
    const result = await runHookRead(
      "/app/priv/repo/migrations/20240101_create_users.exs",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
