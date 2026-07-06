/**
 * Tests for session-log-writer-only hook.
 * Mirrors cases from session-log-writer-only_test.sh minus MultiEdit
 * (Pi has no MultiEdit).
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe(
  "session-log-writer-only",
  { concurrency: 1 },
  () => {
    let _capturedHandler: (event: unknown) => Promise<unknown>;
    let tmpDir: string;
    let logDir: string;

    const mockPi = {
      on: (
        _event: string,
        handler: (event: unknown) => Promise<unknown>,
      ) => {
        _capturedHandler = handler;
      },
    };

    async function loadHook() {
      const { register } = await import("../session-log-writer-only");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
    }

    function writeEvent(filePath: string) {
      return {
        toolName: "write",
        toolCallId: "test-id",
        input: { file_path: filePath, content: "whatever" },
      };
    }

    function editEvent(filePath: string) {
      return {
        toolName: "edit",
        toolCallId: "test-id",
        input: { file_path: filePath, old_string: "a", new_string: "b" },
      };
    }

    function bashEvent(command: string) {
      return {
        toolName: "bash",
        toolCallId: "test-id",
        input: { command },
      };
    }

    function allowed(result: unknown): boolean {
      return result == null || (result as { block?: boolean }).block !== true;
    }

    function denied(result: unknown): boolean {
      return (result as { block?: boolean }).block === true;
    }

    beforeEach(() => {
      delete process.env["CLAUDE_ROLE"];
      delete process.env["PI_ROLE"];
      tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "sls-writer-only-test-"));
      logDir = path.join(tmpDir, "codegen", "logging");
      fs.mkdirSync(logDir, { recursive: true });
    });

    const logPath = () =>
      path.join(logDir, "20260101_120000_test_cycle.jsonl");
    const nonLogMdPath = () =>
      path.join(tmpDir, "codegen", "pitches", "ready", "some-pitch.md");

    // ── Raw Write/Edit on a session log path → DENY ──
    it("Write on session log path — DENY", async () => {
      await loadHook();
      const result = await _capturedHandler(writeEvent(logPath()));
      assert.equal(denied(result), true);
    });

    it("Edit on session log path — DENY", async () => {
      await loadHook();
      const result = await _capturedHandler(editEvent(logPath()));
      assert.equal(denied(result), true);
    });

    // ── Edit/Write on a non-log .md path → ALLOW ──
    it("Write on non-log .md path — ALLOW", async () => {
      await loadHook();
      const result = await _capturedHandler(writeEvent(nonLogMdPath()));
      assert.equal(allowed(result), true);
    });

    it("Edit on non-log .md path — ALLOW", async () => {
      await loadHook();
      const result = await _capturedHandler(editEvent(nonLogMdPath()));
      assert.equal(allowed(result), true);
    });

    // ── Bash writes into a log (redirect, tee, in-place-stream-edit, move-into) → DENY ──
    it("Bash redirect > into log — DENY", async () => {
      await loadHook();
      const result = await _capturedHandler(
        bashEvent("echo hi > codegen/logging/20260101_120000_test_cycle.jsonl"),
      );
      assert.equal(denied(result), true);
    });

    it("Bash append >> into log — DENY", async () => {
      await loadHook();
      const result = await _capturedHandler(
        bashEvent(
          "printf 'x' >> codegen/logging/20260101_120000_test_cycle.jsonl",
        ),
      );
      assert.equal(denied(result), true);
    });

    it("Bash tee into log — DENY", async () => {
      await loadHook();
      const result = await _capturedHandler(
        bashEvent(
          "echo hi | tee -a codegen/logging/20260101_120000_test_cycle.jsonl",
        ),
      );
      assert.equal(denied(result), true);
    });

    it("Bash sed -i in-place-edit on log — DENY", async () => {
      await loadHook();
      const result = await _capturedHandler(
        bashEvent(
          "sed -i '' 's/a/b/' codegen/logging/20260101_120000_test_cycle.jsonl",
        ),
      );
      assert.equal(denied(result), true);
    });

    it("Bash mv into log path — DENY", async () => {
      await loadHook();
      const result = await _capturedHandler(
        bashEvent(
          "mv /tmp/foo.md codegen/logging/20260101_120000_test_cycle.jsonl",
        ),
      );
      assert.equal(denied(result), true);
    });

    // ── codegen-log init/section/section --role/append Bash → ALLOW ──
    it("Bash codegen-log init — ALLOW", async () => {
      await loadHook();
      const result = await _capturedHandler(
        bashEvent("codegen-log init --slug demo"),
      );
      assert.equal(allowed(result), true);
    });

    it("Bash codegen-log section --body @- — ALLOW", async () => {
      await loadHook();
      const result = await _capturedHandler(
        bashEvent("printf 'x' | codegen-log section --body @-"),
      );
      assert.equal(allowed(result), true);
    });

    it("Bash codegen-log section --role — ALLOW", async () => {
      await loadHook();
      const result = await _capturedHandler(
        bashEvent(
          "printf '' | codegen-log section --role reviewer-phoenix --body @-",
        ),
      );
      assert.equal(allowed(result), true);
    });

    it("Bash codegen-log append --role — ALLOW", async () => {
      await loadHook();
      const result = await _capturedHandler(
        bashEvent("printf 'x' | codegen-log append --role committer --body @-"),
      );
      assert.equal(allowed(result), true);
    });

    // ── Unrelated git/read Bash → ALLOW ──
    it("Bash unrelated git status — ALLOW", async () => {
      await loadHook();
      const result = await _capturedHandler(bashEvent("git status"));
      assert.equal(allowed(result), true);
    });

    it("Bash unrelated read (cat other file) — ALLOW", async () => {
      await loadHook();
      const result = await _capturedHandler(bashEvent("cat README.md"));
      assert.equal(allowed(result), true);
    });

    // ── BYPASS debug/shape/ops ──
    it("debug role bypass on Write to log — ALLOW", async () => {
      process.env["CLAUDE_ROLE"] = "debug";
      await loadHook();
      const result = await _capturedHandler(writeEvent(logPath()));
      assert.equal(allowed(result), true);
    });

    it("shape role bypass on Bash redirect into log — ALLOW", async () => {
      process.env["CLAUDE_ROLE"] = "shape";
      await loadHook();
      const result = await _capturedHandler(
        bashEvent("echo hi > codegen/logging/20260101_120000_test_cycle.jsonl"),
      );
      assert.equal(allowed(result), true);
    });

    it("ops role bypass on Edit to log — ALLOW", async () => {
      process.env["CLAUDE_ROLE"] = "ops";
      await loadHook();
      const result = await _capturedHandler(editEvent(logPath()));
      assert.equal(allowed(result), true);
    });
  },
);
