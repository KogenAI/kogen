/**
 * Tests for codegen-tools.ts — the Pi twin of harnesses/claude/mcp-server/.
 *
 * Mirrors the Claude MCP server's fixture set (server.test.ts): role-baked
 * argv, stdin body, isError propagation, reader shapes. Plus a NAME-SET
 * PARITY assertion against a literal expected list (not derived from the
 * module itself — a derived comparison would be tautological).
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

async function withTmpDir(fn: (dir: string) => void | Promise<void>) {
  const dir = mkdtempSync(join(tmpdir(), "pi-codegen-tools-test-"));
  try {
    await fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Literal expected set — mirrors harnesses/claude/mcp-server/src/roles.ts
// ROLES exactly. Deliberately NOT derived from CODEGEN_TOOL_NAMES itself,
// so this assertion can actually fail if either side drifts.
const EXPECTED_CLAUDE_TOOL_NAMES = [
  "mcp__codegen__gate_status",
  "mcp__codegen__log_append_committer",
  "mcp__codegen__log_append_context_curator",
  "mcp__codegen__log_append_developer_phoenix_backend",
  "mcp__codegen__log_append_developer_phoenix_frontend",
  "mcp__codegen__log_append_developer_static",
  "mcp__codegen__log_append_planner_phoenix",
  "mcp__codegen__log_append_planner_static",
  "mcp__codegen__log_append_reviewer_phoenix",
  "mcp__codegen__log_append_reviewer_static",
  "mcp__codegen__log_read",
  "mcp__codegen__log_section_committer",
  "mcp__codegen__log_section_context_curator",
  "mcp__codegen__log_section_developer_phoenix_backend",
  "mcp__codegen__log_section_developer_phoenix_frontend",
  "mcp__codegen__log_section_developer_static",
  "mcp__codegen__log_section_planner_phoenix",
  "mcp__codegen__log_section_planner_static",
  "mcp__codegen__log_section_reviewer_phoenix",
  "mcp__codegen__log_section_reviewer_static",
].sort();

describe("codegen-tools — Claude/Pi tool-name-set parity", () => {
  it("bare Pi names, once prefixed with mcp__codegen__, equal the Claude tool set", async () => {
    const { CODEGEN_TOOL_NAMES } = await import("../../codegen-tools");
    const prefixed = CODEGEN_TOOL_NAMES.map((n: string) => `mcp__codegen__${n}`).sort();
    assert.deepEqual(prefixed, EXPECTED_CLAUDE_TOOL_NAMES);
  });

  it("registers exactly 20 tools (9 roles x 2 writers + 2 readers)", async () => {
    const { CODEGEN_TOOL_NAMES } = await import("../../codegen-tools");
    assert.equal(CODEGEN_TOOL_NAMES.length, 20);
  });
});

describe("codegen-tools — register() wires every tool via pi.registerTool", () => {
  it("calls registerTool exactly 20 times with unique names", async () => {
    const registered: string[] = [];
    const mockPi = {
      registerTool: (tool: { name: string }) => {
        registered.push(tool.name);
      },
    };
    const { register } = await import("../../codegen-tools");
    register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
    assert.equal(registered.length, 20);
    assert.equal(new Set(registered).size, 20);
  });

  it("a generated section tool's execute() calls codegen-log with --role baked in, never as a caller arg", async () => {
    await withTmpDir(async (dir) => {
      const fakeBin = join(dir, "codegen-log");
      writeFileSync(fakeBin, "#!/usr/bin/env bash\nprintf 'ARGV:%s\\n' \"$*\"\nprintf 'STDIN:'\ncat\n", {
        mode: 0o755,
      });
      const oldPath = process.env.PATH;
      process.env.PATH = `${dir}:${oldPath}`;
      try {
        const tools: Record<string, any> = {};
        const mockPi = {
          registerTool: (tool: any) => {
            tools[tool.name] = tool;
          },
        };
        const { register } = await import("../../codegen-tools");
        register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);

        const sectionTool = tools["log_section_developer_phoenix_backend"];
        assert.ok(sectionTool, "expected log_section_developer_phoenix_backend to be registered");

        const result = await sectionTool.execute("call-1", { body: "hello `backticks` $(danger)" });
        const text = result.content[0].text as string;
        assert.match(text, /^ARGV:section developer-phoenix-backend$/m);
        assert.match(text, /STDIN:hello `backticks` \$\(danger\)/);
      } finally {
        process.env.PATH = oldPath;
      }
    });
  });

  it("a non-zero codegen-log exit surfaces as a thrown Error, never swallowed (Pi contract: throw on failure)", async () => {
    await withTmpDir(async (dir) => {
      const fakeBin = join(dir, "codegen-log");
      writeFileSync(fakeBin, "#!/usr/bin/env bash\nprintf 'boom\\n' >&2\nexit 2\n", { mode: 0o755 });
      const oldPath = process.env.PATH;
      process.env.PATH = `${dir}:${oldPath}`;
      try {
        const tools: Record<string, any> = {};
        const mockPi = {
          registerTool: (tool: any) => {
            tools[tool.name] = tool;
          },
        };
        const { register } = await import("../../codegen-tools");
        register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);

        const sectionTool = tools["log_section_reviewer_phoenix"];
        await assert.rejects(() => sectionTool.execute("call-1", { body: "x" }), /boom/);
      } finally {
        process.env.PATH = oldPath;
      }
    });
  });

  it("gate_status reads verdict/exit/witness from a fixture gate-result.json", async () => {
    await withTmpDir(async (dir) => {
      mkdirSync(join(dir, "codegen", "gate-pending"), { recursive: true });
      writeFileSync(
        join(dir, "codegen", "gate-pending", "gate-result.json"),
        JSON.stringify({ verdict: "clear", exit: 0, diff_files_count: 4, ended: "2026-07-19T04:00:00Z", witness: "" }),
      );
      const tools: Record<string, any> = {};
      const mockPi = {
        registerTool: (tool: any) => {
          tools[tool.name] = tool;
        },
      };
      const { register } = await import("../../codegen-tools");
      register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);

      const result = await tools["gate_status"].execute("call-1", { cwd: dir });
      const parsed = JSON.parse(result.content[0].text as string);
      assert.equal(parsed.verdict, "clear");
      assert.equal(parsed.exit, 0);
    });
  });

  it("log_read manifest view returns only plan/plan_gate/files_to_touch events", async () => {
    await withTmpDir(async (dir) => {
      mkdirSync(join(dir, "codegen", "logging"), { recursive: true });
      const logPath = join(dir, "codegen", "logging", "20260719_000000_fixture-slug_cycle.jsonl");
      const lines = [
        { ev: "role", role: "planner-phoenix", body: "did planning" },
        { ev: "plan", role: "planner-phoenix", plan: "the plan text" },
        { ev: "files_to_touch", role: "planner-phoenix", files: ["a.ex"] },
      ];
      writeFileSync(logPath, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
      writeFileSync(join(dir, "codegen", "logging", ".active"), logPath);

      const savedEnv = process.env.CODEGEN_LOG_PATH;
      delete process.env.CODEGEN_LOG_PATH;
      try {
        const tools: Record<string, any> = {};
        const mockPi = {
          registerTool: (tool: any) => {
            tools[tool.name] = tool;
          },
        };
        const { register } = await import("../../codegen-tools");
        register(mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);

        const result = await tools["log_read"].execute("call-1", { cwd: dir, view: "manifest" });
        const parsed = JSON.parse(result.content[0].text as string);
        assert.equal(parsed.events.length, 2);
      } finally {
        if (savedEnv !== undefined) process.env.CODEGEN_LOG_PATH = savedEnv;
      }
    });
  });
});
