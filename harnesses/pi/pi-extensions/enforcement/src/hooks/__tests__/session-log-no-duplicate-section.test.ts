/**
 * Tests for session-log-no-duplicate-section hook.
 * Mirrors key cases from session-log-no-duplicate-section_test.sh.
 * (MultiEdit cases omitted — Pi has no MultiEdit.)
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe(
  "session-log-no-duplicate-section",
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
      // Re-import per test to pick up fresh env state.
      const { register } = await import("../session-log-no-duplicate-section");
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
    }

    function writeEvent(filePath: string, content: string) {
      return {
        toolName: "write",
        toolCallId: "test-id",
        input: { file_path: filePath, content },
      };
    }

    function editEvent(
      filePath: string,
      oldString: string,
      newString: string,
    ) {
      return {
        toolName: "edit",
        toolCallId: "test-id",
        input: { file_path: filePath, old_string: oldString, new_string: newString },
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
      tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "sls-nodup-test-"));
      logDir = path.join(tmpDir, "codegen", "logging");
      fs.mkdirSync(logDir, { recursive: true });
    });

    // ── Test 1: Write with duplicated section header → DENY ──
    it("Write with duplicate header in content — DENY", async () => {
      const logFile = path.join(logDir, "dup_write.md");
      await loadHook();
      const content =
        "# Step\n\n## developer-phoenix-backend Section\n\nbody\n\n## developer-phoenix-backend Section\n\ndup";
      const result = await _capturedHandler(writeEvent(logFile, content));
      assert.ok(denied(result), `Expected DENY, got: ${JSON.stringify(result)}`);
    });

    // ── Test 2: Write with Plan and one role header once → ALLOW ──
    it("Write with Plan and one role header — ALLOW", async () => {
      const logFile = path.join(logDir, "single_write.md");
      await loadHook();
      const content =
        "# Step\n\n## Plan\n\nplan text\n\n## developer-phoenix-backend Section\n\nbody";
      const result = await _capturedHandler(writeEvent(logFile, content));
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 3: Edit replacing the on-disk header line — net-zero → ALLOW ──
    // (Canonical reviewer follow-up: old_string carries the header, so the
    // result still has exactly one copy.)
    it("Edit replacing on-disk header line — net-zero — ALLOW", async () => {
      const logFile = path.join(logDir, "replace_header.md");
      fs.writeFileSync(logFile, "## reviewer-phoenix Section\n\n<placeholder>\n");
      await loadHook();
      const result = await _capturedHandler(
        editEvent(
          logFile,
          "## reviewer-phoenix Section\n\n<placeholder>",
          "## reviewer-phoenix Section\n\n**Verdict**: QUALITY APPROVED\n\nFindings.",
        ),
      );
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 4: Edit adding header NOT yet on disk → ALLOW (first insertion) ──
    it("Edit adding header not yet on disk — ALLOW", async () => {
      const logFile = path.join(logDir, "add_header.md");
      fs.writeFileSync(logFile, "# Step\n\n## Plan\n\nplan text\n");
      await loadHook();
      const result = await _capturedHandler(
        editEvent(logFile, "", "## developer-phoenix-backend Section\n\nbody"),
      );
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 5: Edit new_string containing the same header twice → DENY (self-dup) ──
    it("Edit new_string with same header 2x in payload — DENY (self-dup)", async () => {
      const logFile = path.join(logDir, "self_dup.md");
      fs.writeFileSync(logFile, "# Step\n\n## Plan\n\nplan\n");
      await loadHook();
      const result = await _capturedHandler(
        editEvent(
          logFile,
          "",
          "## developer-phoenix-backend Section\n\nbody\n\n## developer-phoenix-backend Section\n\ndup",
        ),
      );
      assert.ok(denied(result), `Expected DENY, got: ${JSON.stringify(result)}`);
    });

    // ── Test 6: Genuine 2nd-copy DENY ──
    // old_string does NOT carry the header, but new_string adds a header that
    // already exists elsewhere on disk → result has 2 copies → DENY.
    it("Genuine 2nd-copy: new_string adds header already on disk — DENY", async () => {
      const logFile = path.join(logDir, "genuine_dup.md");
      fs.writeFileSync(
        logFile,
        "# Step\n\n## developer-phoenix-backend Section\n\noriginal body\n\nsome other line\n",
      );
      await loadHook();
      const result = await _capturedHandler(
        editEvent(
          logFile,
          "some other line",
          "## developer-phoenix-backend Section\n\nsecond copy",
        ),
      );
      assert.ok(denied(result), `Expected DENY, got: ${JSON.stringify(result)}`);
    });

    // ── Test 7: Non-logging path Edit duplicating a header → ALLOW (not a session log) ──
    it("Edit on non-logging path with dup header — ALLOW", async () => {
      const libDir = path.join(tmpDir, "lib");
      fs.mkdirSync(libDir, { recursive: true });
      const libFile = path.join(libDir, "foo.ex");
      fs.writeFileSync(libFile, "# some elixir\n");
      await loadHook();
      const result = await _capturedHandler(
        editEvent(
          libFile,
          "",
          "## developer-phoenix-backend Section\n\n## developer-phoenix-backend Section\n\n",
        ),
      );
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 8: CLAUDE_ROLE=debug Edit duplicating a header → ALLOW (bypass) ──
    it("CLAUDE_ROLE=debug bypasses guard — ALLOW", async () => {
      const logFile = path.join(logDir, "debug_dup.md");
      fs.writeFileSync(logFile, "## developer-phoenix-backend Section\n\nbody\n");
      process.env["CLAUDE_ROLE"] = "debug";
      await loadHook();
      const result = await _capturedHandler(
        editEvent(logFile, "", "## developer-phoenix-backend Section\n\ndup"),
      );
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 9: Edit on non-existent log file → ALLOW (fail-open) ──
    it("Edit on non-existent log file — ALLOW (fail-open)", async () => {
      const nonexistent = path.join(logDir, "does-not-exist.md");
      await loadHook();
      const result = await _capturedHandler(
        editEvent(nonexistent, "", "## developer-phoenix-backend Section\n\nbody"),
      );
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });
  },
);
