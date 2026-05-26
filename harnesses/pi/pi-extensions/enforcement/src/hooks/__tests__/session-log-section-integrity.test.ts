/**
 * Tests for session-log-section-integrity hook.
 * Mirrors cases from session-log-section-integrity_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("session-log-section-integrity", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  let tmpDir: string;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function register(agentType: string) {
    process.env["AGENT_TYPE"] = agentType;
    const { register: reg } = await import("../session-log-section-integrity");
    reg(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "sls-test-"));
    fs.mkdirSync(path.join(tmpDir, "codegen", "logging"), { recursive: true });
  });

  it("allows Edit with section header in new_string", async () => {
    const logFile = path.join(tmpDir, "codegen", "logging", "foo.md");
    fs.writeFileSync(logFile, "");
    await register("developer-phoenix-backend");
    const result = await _capturedHandler({
      toolName: "edit",
      toolCallId: "test-id",
      input: {
        file_path: logFile,
        old_string: "",
        new_string: "## developer-phoenix-backend Section\n\nSome content",
      },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks Edit without section header in new_string", async () => {
    const logFile = path.join(tmpDir, "codegen", "logging", "foo.md");
    fs.writeFileSync(logFile, "");
    await register("developer-phoenix-backend");
    const result = await _capturedHandler({
      toolName: "edit",
      toolCallId: "test-id",
      input: {
        file_path: logFile,
        old_string: "",
        new_string: "Some content without the required header",
      },
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows follow-up edit when section already exists in file", async () => {
    const logFile = path.join(tmpDir, "codegen", "logging", "foo.md");
    fs.writeFileSync(
      logFile,
      "## developer-phoenix-backend Section\n\nExisting content\n",
    );
    await register("developer-phoenix-backend");
    const result = await _capturedHandler({
      toolName: "edit",
      toolCallId: "test-id",
      input: {
        file_path: logFile,
        old_string: "Existing content",
        new_string: "Additional content",
      },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows Write with section header in content", async () => {
    const newLogFile = path.join(
      tmpDir,
      "codegen",
      "logging",
      "new-session.md",
    );
    await register("developer-phoenix-backend");
    const result = await _capturedHandler({
      toolName: "write",
      toolCallId: "test-id",
      input: {
        file_path: newLogFile,
        content: "# Step\n\n## developer-phoenix-backend Section\n\nbody",
      },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks Write without section header in content", async () => {
    const newLogFile = path.join(tmpDir, "codegen", "logging", "another.md");
    await register("developer-phoenix-backend");
    const result = await _capturedHandler({
      toolName: "write",
      toolCallId: "test-id",
      input: { file_path: newLogFile, content: "# Step\n\nNo header here" },
    });
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows planner Edit without section header (planner writes ## Plan)", async () => {
    const plannerLog = path.join(
      tmpDir,
      "codegen",
      "logging",
      "planner-session.md",
    );
    fs.writeFileSync(plannerLog, "");
    await register("planner");
    const result = await _capturedHandler({
      toolName: "edit",
      toolCallId: "test-id",
      input: {
        file_path: plannerLog,
        old_string: "",
        new_string: "## Plan\n\nStep 1: do thing",
      },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("does not block edits to non-session-log files", async () => {
    const libFile = path.join(tmpDir, "lib", "foo.ex");
    fs.mkdirSync(path.join(tmpDir, "lib"), { recursive: true });
    fs.writeFileSync(libFile, "");
    await register("developer-phoenix-backend");
    const result = await _capturedHandler({
      toolName: "edit",
      toolCallId: "test-id",
      input: {
        file_path: libFile,
        old_string: "",
        new_string: "some code without header",
      },
    });
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
