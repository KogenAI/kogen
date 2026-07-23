/**
 * Tests for orchestrator-no-source-edit hook.
 * Mirrors cases from orchestrator-no-source-edit_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, input: Record<string, string>) {
  return { toolName, toolCallId: "test-id", input };
}

describe("orchestrator-no-source-edit", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    toolName: string,
    input: Record<string, string>,
    env: { AGENT_TYPE?: string; PI_ROLE?: string } = {},
  ) {
    const saved: Record<string, string | undefined> = {};
    for (const k of ["AGENT_TYPE", "PI_ROLE"] as const) {
      saved[k] = process.env[k];
      if (k in env && env[k] !== undefined) {
        process.env[k] = env[k];
      } else {
        delete process.env[k];
      }
    }

    try {
      const { register } = await import("../orchestrator-no-source-edit");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      return _capturedHandler(makeToolCallEvent(toolName, input));
    } finally {
      for (const [k, v] of Object.entries(saved)) {
        if (v === undefined) delete process.env[k];
        else process.env[k] = v;
      }
    }
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["PI_ROLE"];
  });

  it("blocks orchestrator Edit on lib/ (no role)", async () => {
    const result = await runHook("edit", { file_path: "lib/my_app/foo.ex" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows subagent (AGENT_TYPE set) Edit on lib/", async () => {
    const result = await runHook(
      "edit",
      { file_path: "lib/my_app/foo.ex" },
      { AGENT_TYPE: "developer-phoenix-backend" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows orchestrator Write to codegen/logging/ (no role)", async () => {
    const result = await runHook("write", { file_path: "codegen/logging/x.md" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks orchestrator Write on CLAUDE.md (no role)", async () => {
    const result = await runHook("write", { file_path: "CLAUDE.md" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows orchestrator Write on absolute /tmp/ (no role)", async () => {
    const result = await runHook("write", { file_path: "/tmp/scratch.txt" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks debug mode Edit on lib/", async () => {
    const result = await runHook(
      "edit",
      { file_path: "lib/my_app/foo.ex" },
      { PI_ROLE: "debug" },
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks debug mode Edit on codegen/logging/ (debug only writes pitches/)", async () => {
    const result = await runHook(
      "edit",
      { file_path: "codegen/logging/session.md" },
      { PI_ROLE: "debug" },
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows debug mode Write to codegen/pitches/draft/", async () => {
    const result = await runHook(
      "write",
      { file_path: "codegen/pitches/draft/foo.md" },
      { PI_ROLE: "debug" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows shape mode Write to codegen/pitches/draft/", async () => {
    const result = await runHook(
      "write",
      { file_path: "codegen/pitches/draft/foo.md" },
      { PI_ROLE: "shape" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks shape mode Edit on lib/", async () => {
    const result = await runHook(
      "edit",
      { file_path: "lib/my_app/foo.ex" },
      { PI_ROLE: "shape" },
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows ops mode Edit on lib/ (full write surface)", async () => {
    const result = await runHook(
      "edit",
      { file_path: "lib/my_app/foo.ex" },
      { PI_ROLE: "ops" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows babysit mode Edit on lib/ (full write surface)", async () => {
    const result = await runHook(
      "edit",
      { file_path: "lib/my_app/foo.ex" },
      { PI_ROLE: "babysit" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows experiment mode Edit on lib/ (worktree is the boundary)", async () => {
    const result = await runHook(
      "edit",
      { file_path: "lib/my_app/foo.ex" },
      { PI_ROLE: "experiment" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows experiment mode Edit on arbitrary on-box path", async () => {
    const result = await runHook(
      "edit",
      { file_path: "/srv/app.ex" },
      { PI_ROLE: "experiment" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks debug mode subagent Edit on lib/ (subagent bypass disabled under debug/shape)", async () => {
    const result = await runHook(
      "edit",
      { file_path: "lib/my_app/foo.ex" },
      { PI_ROLE: "debug", AGENT_TYPE: "general-purpose" },
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("denies debug mode empty file path (fail-closed)", async () => {
    const result = await runHook("write", { file_path: "" }, { PI_ROLE: "debug" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("denies plain orchestrator empty file path (fail-closed)", async () => {
    const result = await runHook("write", { file_path: "" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows named agent (AGENT_TYPE set) Edit on lib/", async () => {
    const result = await runHook(
      "edit",
      { file_path: "lib/my_app/foo.ex" },
      { AGENT_TYPE: "developer-static" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("ignores non-file tools", async () => {
    const result = await runHook("bash", { command: "ls" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
