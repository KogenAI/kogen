/**
 * Tests for subagent-read-discipline hook.
 * Mirrors cases from subagent-read-discipline_test.sh.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";

function makeToolCallEvent(toolName: string, input: Record<string, string>) {
  return { toolName, toolCallId: "test-id", input };
}

describe("subagent-read-discipline", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;
  let tmpDir: string;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    filePath: string,
    agentType: string,
    cycleLogPath?: string,
  ) {
    const savedAgent = process.env["AGENT_TYPE"];
    const savedLog = process.env["CODEGEN_LOG_PATH"];
    if (agentType) process.env["AGENT_TYPE"] = agentType;
    else delete process.env["AGENT_TYPE"];
    if (cycleLogPath) process.env["CODEGEN_LOG_PATH"] = cycleLogPath;
    else delete process.env["CODEGEN_LOG_PATH"];

    try {
      const { register } = await import("../subagent-read-discipline");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      return _capturedHandler(makeToolCallEvent("read", { file_path: filePath }));
    } finally {
      if (savedAgent === undefined) delete process.env["AGENT_TYPE"];
      else process.env["AGENT_TYPE"] = savedAgent;
      if (savedLog === undefined) delete process.env["CODEGEN_LOG_PATH"];
      else process.env["CODEGEN_LOG_PATH"] = savedLog;
    }
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
    delete process.env["CODEGEN_LOG_PATH"];
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "subagent-read-disc-"));
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it("allows context-curator to read the pitch", async () => {
    const result = await runHook(
      "codegen/pitches/draft/foo.md",
      "context-curator",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows context-curator to read context/*.md", async () => {
    const result = await runHook("context/harnesses.md", "context-curator");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks committer reading the pitch", async () => {
    const result = await runHook("codegen/pitches/draft/foo.md", "committer");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks committer reading PROJECT_CONTEXT.md", async () => {
    const result = await runHook("PROJECT_CONTEXT.md", "committer");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks committer reading context/*.md", async () => {
    const result = await runHook("context/harnesses.md", "committer");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks developer-* reading the pitch", async () => {
    const result = await runHook(
      "codegen/pitches/draft/foo.md",
      "developer-phoenix-backend",
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks developer-* reading PROJECT_CONTEXT.md", async () => {
    const result = await runHook("PROJECT_CONTEXT.md", "developer-phoenix-backend");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks developer-* reading context/*.md not in the loop's files_to_touch", async () => {
    const logPath = path.join(tmpDir, "cycle.jsonl");
    fs.writeFileSync(
      logPath,
      JSON.stringify({
        ev: "files_to_touch",
        role: "loop",
        files: ["context/other.md"],
      }) + "\n",
    );
    const result = await runHook(
      "context/harnesses.md",
      "developer-phoenix-backend",
      logPath,
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows developer-* reading context/*.md listed in the loop's files_to_touch", async () => {
    const logPath = path.join(tmpDir, "cycle.jsonl");
    fs.writeFileSync(
      logPath,
      JSON.stringify({
        ev: "files_to_touch",
        role: "loop",
        files: ["context/harnesses.md"],
      }) + "\n",
    );
    const result = await runHook(
      "context/harnesses.md",
      "developer-phoenix-backend",
      logPath,
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks developer-* when the files_to_touch event is developer-authored (self-authorization guard)", async () => {
    const logPath = path.join(tmpDir, "cycle.jsonl");
    fs.writeFileSync(
      logPath,
      JSON.stringify({
        ev: "files_to_touch",
        role: "developer-phoenix-backend",
        files: ["context/harnesses.md"],
      }) + "\n",
    );
    const result = await runHook(
      "context/harnesses.md",
      "developer-phoenix-backend",
      logPath,
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks developer-* when only its own files_modified event names the path", async () => {
    const logPath = path.join(tmpDir, "cycle.jsonl");
    fs.writeFileSync(
      logPath,
      JSON.stringify({
        ev: "files_modified",
        role: "developer-phoenix-backend",
        files: ["context/harnesses.md"],
      }) + "\n",
    );
    const result = await runHook(
      "context/harnesses.md",
      "developer-phoenix-backend",
      logPath,
    );
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("fail-opens developer-* context/*.md read when no step log resolvable", async () => {
    const result = await runHook(
      "context/harnesses.md",
      "developer-phoenix-backend",
      path.join(tmpDir, "does-not-exist.jsonl"),
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("blocks reviewer-* reading the pitch", async () => {
    const result = await runHook("codegen/pitches/draft/foo.md", "reviewer-phoenix");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks reviewer-* reading context/*.md not in developer's files_modified", async () => {
    const logPath = path.join(tmpDir, "cycle.jsonl");
    fs.writeFileSync(
      logPath,
      JSON.stringify({
        ev: "files_modified",
        role: "developer-phoenix-backend",
        files: ["context/other.md"],
      }) + "\n",
    );
    const result = await runHook("context/harnesses.md", "reviewer-phoenix", logPath);
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows reviewer-* reading context/*.md listed in developer's files_modified", async () => {
    const logPath = path.join(tmpDir, "cycle.jsonl");
    fs.writeFileSync(
      logPath,
      JSON.stringify({
        ev: "files_modified",
        role: "developer-phoenix-backend",
        files: ["context/harnesses.md"],
      }) + "\n",
    );
    const result = await runHook("context/harnesses.md", "reviewer-phoenix", logPath);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through unknown AGENT_TYPE", async () => {
    const result = await runHook("context/harnesses.md", "unknown-role");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows any role reading unrelated files", async () => {
    const result = await runHook("lib/my_app/foo.ex", "developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("skips gating when AGENT_TYPE is empty (orchestrator)", async () => {
    const result = await runHook("codegen/pitches/draft/foo.md", "");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
