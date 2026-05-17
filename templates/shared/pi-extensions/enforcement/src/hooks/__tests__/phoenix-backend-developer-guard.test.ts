/**
 * Tests for phoenix-backend-developer-guard hook.
 * Mirrors cases from phoenix-backend-developer-guard_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeEditEvent(filePath: string, agentType: string) {
  return {
    toolName: "edit",
    toolCallId: "test-id",
    input: { file_path: filePath },
  };
}

describe("phoenix-backend-developer-guard", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHookEdit(
    filePath: string,
    agentType = "developer-phoenix-backend",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../phoenix-backend-developer-guard");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeEditEvent(filePath, agentType));
  }

  async function runHookRead(
    filePath: string,
    agentType = "developer-phoenix-backend",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../phoenix-backend-developer-guard");
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

  it("blocks Edit on lib/app_web/", async () => {
    const result = await runHookEdit("/app/lib/my_app_web/live/user_live.ex");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks Edit on assets/js/", async () => {
    const result = await runHookEdit("/app/assets/js/app.js");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks Edit on priv/static/", async () => {
    const result = await runHookEdit("/app/priv/static/css/app.css");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks Edit on .heex files", async () => {
    const result = await runHookEdit(
      "/app/lib/my_app_web/templates/page.html.heex",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks Edit on _html.ex files", async () => {
    const result = await runHookEdit(
      "/app/lib/my_app_web/controllers/page_html.ex",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows Edit on lib/my_app/ (backend)", async () => {
    const result = await runHookEdit("/app/lib/my_app/accounts/user.ex");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Edit on priv/repo/migrations/", async () => {
    const result = await runHookEdit(
      "/app/priv/repo/migrations/20240101_create_users.exs",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Edit by frontend agent (pass-through)", async () => {
    const result = await runHookEdit(
      "/app/lib/my_app_web/live/user_live.ex",
      "developer-phoenix-frontend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Read on _web path (not gated tool)", async () => {
    const result = await runHookRead("/app/lib/my_app_web/live/user_live.ex");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
