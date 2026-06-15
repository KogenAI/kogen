/**
 * Tests for orchestrator-read-discipline hook.
 * Mirrors cases from orchestrator-read-discipline_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeToolCallEvent(toolName: string, input: Record<string, string>) {
  return { toolName, toolCallId: "test-id", input };
}

describe("orchestrator-read-discipline", () => {
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
    // Save and set env vars
    const saved: Record<string, string | undefined> = {};
    for (const [k, v] of Object.entries(env)) {
      saved[k] = process.env[k];
      process.env[k] = v;
    }
    // Ensure AGENT_TYPE is cleared when not specified (orchestrator)
    if (!("AGENT_TYPE" in env)) {
      saved["AGENT_TYPE"] = process.env["AGENT_TYPE"];
      delete process.env["AGENT_TYPE"];
    }
    if (!("PI_ROLE" in env)) {
      saved["PI_ROLE"] = process.env["PI_ROLE"];
      delete process.env["PI_ROLE"];
    }

    try {
      const { register } = await import("../orchestrator-read-discipline");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      return _capturedHandler(makeToolCallEvent(toolName, input));
    } finally {
      // Restore env vars
      for (const [k, v] of Object.entries(saved)) {
        if (v === undefined) {
          delete process.env[k];
        } else {
          process.env[k] = v;
        }
      }
    }
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["PI_ROLE"];
  });

  // ── Read allowlist tests ──────────────────────────────────────────────────

  it("allows orchestrator Read on session log", async () => {
    const result = await runHook("read", {
      file_path: "codegen/logging/20260509_session.md",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks orchestrator Read on PROJECT_CONTEXT.md", async () => {
    const result = await runHook("read", { file_path: "PROJECT_CONTEXT.md" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks orchestrator Read on lib/ file", async () => {
    const result = await runHook("read", {
      file_path: "lib/my_app/apps.ex",
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows orchestrator Read on codegen/rules/roles/orchestrator.md", async () => {
    const result = await runHook("read", {
      file_path: "codegen/rules/roles/orchestrator.md",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows orchestrator Read on codegen/rules/_core/bash-discipline.md", async () => {
    const result = await runHook("read", {
      file_path: "codegen/rules/_core/bash-discipline.md",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks orchestrator Read on codegen/rules/stacks/phoenix/developer.md (subagent rule)", async () => {
    const result = await runHook("read", {
      file_path: "codegen/rules/stacks/phoenix/developer.md",
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows orchestrator Read on codegen/token-budget-design.md (top-level design doc)", async () => {
    const result = await runHook("read", {
      file_path: "codegen/token-budget-design.md",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks orchestrator Read on codegen/recipes/foo.md (subdir not allowed)", async () => {
    const result = await runHook("read", {
      file_path: "codegen/recipes/foo.md",
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows orchestrator Read on codegen/pitches/draft/foo.md", async () => {
    const result = await runHook("read", {
      file_path: "codegen/pitches/draft/foo.md",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows orchestrator Read on codegen/pitches/ready/foo.md", async () => {
    const result = await runHook("read", {
      file_path: "codegen/pitches/ready/foo.md",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks orchestrator Read on codegen/PROJECT_CONTEXT.md (subdir form)", async () => {
    const result = await runHook("read", {
      file_path: "codegen/PROJECT_CONTEXT.md",
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Bash DENY tests ───────────────────────────────────────────────────────

  it("blocks orchestrator Bash grep -rn foo lib/", async () => {
    const result = await runHook("bash", { command: "grep -rn foo lib/" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks orchestrator Bash rg foo", async () => {
    const result = await runHook("bash", { command: "rg foo" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks orchestrator Bash find . -name '*.ex'", async () => {
    const result = await runHook("bash", { command: "find . -name '*.ex'" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks orchestrator Bash ls lib/", async () => {
    const result = await runHook("bash", { command: "ls lib/" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks orchestrator Bash tree lib/", async () => {
    const result = await runHook("bash", { command: "tree lib/" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks orchestrator Bash cat lib/foo.ex", async () => {
    const result = await runHook("bash", { command: "cat lib/foo.ex" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks orchestrator Bash leading-whitespace grep", async () => {
    const result = await runHook("bash", { command: "  grep x" });
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Bash ALLOW tests ──────────────────────────────────────────────────────

  it("allows orchestrator Bash git status", async () => {
    const result = await runHook("bash", { command: "git status" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows orchestrator Bash git diff -- lib/foo.ex", async () => {
    const result = await runHook("bash", { command: "git diff -- lib/foo.ex" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows orchestrator Bash git log origin/main..HEAD --oneline", async () => {
    const result = await runHook("bash", {
      command: "git log origin/main..HEAD --oneline",
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows orchestrator Bash make gate-status", async () => {
    const result = await runHook("bash", { command: "make gate-status" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows orchestrator Bash date -u +%Y%m%d", async () => {
    const result = await runHook("bash", { command: "date -u +%Y%m%d" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows orchestrator Bash git log --grep=foo (grep not leading)", async () => {
    const result = await runHook("bash", { command: "git log --grep=foo" });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Bypass tests ──────────────────────────────────────────────────────────

  it("allows subagent (AGENT_TYPE=developer-phoenix-backend) Bash grep", async () => {
    const result = await runHook(
      "bash",
      { command: "grep -rn foo lib/" },
      { AGENT_TYPE: "developer-phoenix-backend" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows planner (AGENT_TYPE=planner) Bash grep", async () => {
    const result = await runHook(
      "bash",
      { command: "grep -rn foo lib/" },
      { AGENT_TYPE: "planner" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows PI_ROLE=debug Bash grep", async () => {
    const result = await runHook(
      "bash",
      { command: "grep foo" },
      { PI_ROLE: "debug" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows PI_ROLE=shape Bash find", async () => {
    const result = await runHook(
      "bash",
      { command: "find ." },
      { PI_ROLE: "shape" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows subagent (AGENT_TYPE=planner) Read on lib/ file", async () => {
    const result = await runHook(
      "read",
      { file_path: "lib/my_app/apps.ex" },
      { AGENT_TYPE: "planner" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows PI_ROLE=debug Read on lib/ file", async () => {
    const result = await runHook(
      "read",
      { file_path: "lib/my_app/apps.ex" },
      { PI_ROLE: "debug" },
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
