/**
 * Tests for session-log-structure hook.
 * Mirrors cases 1-16 and 18 from session-log-structure_test.sh.
 * (Case 17 MultiEdit omitted — Pi has no MultiEdit.)
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe(
  "session-log-structure",
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
      const { register } = await import("../session-log-structure");
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
      tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "sls-struct-test-"));
      logDir = path.join(tmpDir, "codegen", "logging");
      fs.mkdirSync(logDir, { recursive: true });
    });

    // ── Test 1: Write new (non-existent) file, canonical order → ALLOW ──
    it("Write new file, canonical order — ALLOW", async () => {
      const logFile = path.join(logDir, "new_session.md");
      await loadHook();
      const content = [
        "# Step 1",
        "",
        "## Version Stamp",
        "",
        "- hash",
        "",
        "## Plan",
        "",
        "plan",
        "",
        "## Delegation Timeline",
        "",
        "| T | A |",
        "",
        "## Files Modified",
        "",
        "foo",
        "",
        "## developer-phoenix-backend Section",
        "",
        "body",
        "",
        "## reviewer-phoenix Section",
        "",
        "review",
        "",
        "## committer Section",
        "",
        "commit",
      ].join("\n");
      const result = await _capturedHandler(writeEvent(logFile, content));
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 2: Write new file, out-of-order headers → DENY ──
    it("Write new file, out-of-order (committer before developer) — DENY", async () => {
      const logFile = path.join(logDir, "new_session2.md");
      await loadHook();
      const content = [
        "# Step 1",
        "",
        "## Plan",
        "",
        "plan",
        "",
        "## committer Section",
        "",
        "commit",
        "",
        "## developer-phoenix-backend Section",
        "",
        "body",
      ].join("\n");
      const result = await _capturedHandler(writeEvent(logFile, content));
      assert.ok(denied(result), `Expected DENY, got: ${JSON.stringify(result)}`);
    });

    // ── Test 3: Write to existing log dropping ## Plan → DENY ──
    it("Write to existing log dropping ## Plan — DENY", async () => {
      const logFile = path.join(logDir, "existing.md");
      fs.writeFileSync(
        logFile,
        "# Step 1\n\n## Version Stamp\n\n- hash\n\n## Plan\n\nplan\n\n## Delegation Timeline\n\n| T | A |\n",
      );
      await loadHook();
      const content =
        "# Step 1\n\n## Version Stamp\n\n- hash\n\n## Delegation Timeline\n\n| T | A |\n";
      const result = await _capturedHandler(writeEvent(logFile, content));
      assert.ok(denied(result), `Expected DENY, got: ${JSON.stringify(result)}`);
    });

    // ── Test 4: Write to existing log preserving all headers → ALLOW ──
    it("Write to existing log preserving all headers — ALLOW", async () => {
      const logFile = path.join(logDir, "existing2.md");
      fs.writeFileSync(
        logFile,
        "# Step 1\n\n## Plan\n\nplan\n\n## Delegation Timeline\n\n| T | A |\n",
      );
      await loadHook();
      const content =
        "# Step 1\n\n## Plan\n\nplan updated\n\n## Delegation Timeline\n\n| T | A | R |\n";
      const result = await _capturedHandler(writeEvent(logFile, content));
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 5: Edit appending ## developer Section at EOF → ALLOW ──
    it("Edit appending developer Section at EOF — ALLOW", async () => {
      const logFile = path.join(logDir, "append.md");
      fs.writeFileSync(
        logFile,
        "# Step 1\n\n## Plan\n\nplan\n\n## Files Modified\n\nfoo\n",
      );
      await loadHook();
      const result = await _capturedHandler(
        editEvent(logFile, "", "\n## developer-phoenix-backend Section\n\nbody"),
      );
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 6: Edit whose old_string contains ## Plan, new_string omits it → DENY ──
    it("Edit removes ## Plan from old_string without restoring in new_string — DENY", async () => {
      const logFile = path.join(logDir, "remove_plan.md");
      fs.writeFileSync(logFile, "# Step 1\n\n## Plan\n\nplan\n");
      await loadHook();
      const result = await _capturedHandler(
        editEvent(logFile, "## Plan\n\nplan", "no header here"),
      );
      assert.ok(denied(result), `Expected DENY, got: ${JSON.stringify(result)}`);
    });

    // ── Test 7: Edit whose old_string contains ## Plan, new_string re-includes it → ALLOW ──
    it("Edit replaces ## Plan body, keeps ## Plan header — ALLOW", async () => {
      const logFile = path.join(logDir, "keep_plan.md");
      fs.writeFileSync(logFile, "# Step 1\n\n## Plan\n\nplan\n");
      await loadHook();
      const result = await _capturedHandler(
        editEvent(
          logFile,
          "## Plan\n\nplan",
          "## Plan\n\nupdated plan",
        ),
      );
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 8: Edit new_string with reviewer before developer → DENY ──
    it("Edit appending reviewer before developer Section (wrong order) — DENY", async () => {
      const logFile = path.join(logDir, "wrong_order.md");
      fs.writeFileSync(
        logFile,
        "# Step 1\n\n## Plan\n\nplan\n\n## Files Modified\n\nfoo\n",
      );
      await loadHook();
      const newStr =
        "\n## reviewer-phoenix Section\n\nreview\n\n## developer-phoenix-backend Section\n\nbody";
      const result = await _capturedHandler(editEvent(logFile, "", newStr));
      assert.ok(denied(result), `Expected DENY, got: ${JSON.stringify(result)}`);
    });

    // ── Test 9: Edit appending ## reviewer-phoenix Section (pass 2) → ALLOW ──
    it("Edit appending reviewer Section (pass 2) at EOF — ALLOW", async () => {
      const logFile = path.join(logDir, "pass2.md");
      fs.writeFileSync(
        logFile,
        "# Step 1\n\n## Plan\n\nplan\n\n## Files Modified\n\nfoo\n\n## developer-phoenix-backend Section\n\nbody\n\n## reviewer-phoenix Section\n\nreview\n",
      );
      await loadHook();
      const result = await _capturedHandler(
        editEvent(
          logFile,
          "",
          "\n## reviewer-phoenix Section (pass 2)\n\npass2 review",
        ),
      );
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 10: Write with freeform unknown headers interleaved, recognized ones in order → ALLOW ──
    it("Write with unknown headers interleaved, recognized in order — ALLOW", async () => {
      const logFile = path.join(logDir, "interleaved.md");
      await loadHook();
      const content = [
        "# Step 1",
        "",
        "## Some Unknown Header",
        "",
        "data",
        "",
        "## Plan",
        "",
        "plan",
        "",
        "## Another Freeform",
        "",
        "stuff",
        "",
        "## developer-phoenix-backend Section",
        "",
        "body",
      ].join("\n");
      const result = await _capturedHandler(writeEvent(logFile, content));
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 11: CLAUDE_ROLE=debug, out-of-order Write → ALLOW (bypass) ──
    it("CLAUDE_ROLE=debug bypasses guard — ALLOW", async () => {
      const logFile = path.join(logDir, "debug.md");
      process.env["CLAUDE_ROLE"] = "debug";
      await loadHook();
      const content =
        "# Step 1\n\n## committer Section\n\ncommit\n\n## developer-phoenix-backend Section\n\nbody";
      const result = await _capturedHandler(writeEvent(logFile, content));
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 12: CLAUDE_ROLE=shape, header-removing Edit → ALLOW (bypass) ──
    it("CLAUDE_ROLE=shape bypasses guard — ALLOW", async () => {
      const logFile = path.join(logDir, "shape.md");
      fs.writeFileSync(logFile, "# Step 1\n\n## Plan\n\nplan\n");
      process.env["CLAUDE_ROLE"] = "shape";
      await loadHook();
      const result = await _capturedHandler(
        editEvent(logFile, "## Plan\n\nplan", "replaced without header"),
      );
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 13: CLAUDE_ROLE=ops, header-removing Write → ALLOW (bypass) ──
    it("CLAUDE_ROLE=ops bypasses guard — ALLOW", async () => {
      const logFile = path.join(logDir, "ops.md");
      fs.writeFileSync(logFile, "# Step 1\n\n## Plan\n\nplan\n");
      process.env["CLAUDE_ROLE"] = "ops";
      await loadHook();
      const content = "# Step 1\n\nnew content no headers";
      const result = await _capturedHandler(writeEvent(logFile, content));
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 14: Non-logging path (lib/foo.ex) → ALLOW (path gate) ──
    it("Non-logging path — ALLOW (path gate)", async () => {
      const libDir = path.join(tmpDir, "lib");
      fs.mkdirSync(libDir, { recursive: true });
      const libFile = path.join(libDir, "foo.ex");
      fs.writeFileSync(libFile, "# some elixir\n");
      await loadHook();
      const content =
        "## committer Section\n\n## developer-phoenix-backend Section\n";
      const result = await _capturedHandler(writeEvent(libFile, content));
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 15: Non-guarded tool (read) → ALLOW (tool gate) ──
    it("Non-write/edit tool not guarded — ALLOW", async () => {
      const logFile = path.join(logDir, "tool_gate.md");
      fs.writeFileSync(logFile, "# Step 1\n\n## Plan\n\nplan\n");
      await loadHook();
      const result = await _capturedHandler({
        toolName: "read",
        toolCallId: "test-id",
        input: { file_path: logFile },
      });
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 16: Edit on non-existent log → ALLOW (fail-open) ──
    it("Edit on non-existent log — ALLOW (fail-open)", async () => {
      const nonexistent = path.join(logDir, "does-not-exist.md");
      await loadHook();
      const newStr =
        "## committer Section\n\ncommit\n\n## developer-phoenix-backend Section\n\nbody";
      const result = await _capturedHandler(editEvent(nonexistent, "", newStr));
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 18: Write to existing log, all headers preserved but reordered → DENY ──
    it("Write to existing log, headers preserved but reordered — DENY", async () => {
      const logFile = path.join(logDir, "reordered.md");
      fs.writeFileSync(
        logFile,
        "# Step 1\n\n## Plan\n\nplan\n\n## developer-phoenix-backend Section\n\nbody\n",
      );
      await loadHook();
      // developer before Plan in content → out of order
      const content =
        "# Step 1\n\n## developer-phoenix-backend Section\n\nbody\n\n## Plan\n\nplan";
      const result = await _capturedHandler(writeEvent(logFile, content));
      assert.ok(denied(result), `Expected DENY, got: ${JSON.stringify(result)}`);
    });

    // ── Test 19: In-place ## Plan edit with downstream sections on disk → ALLOW ──
    // Regression: naive merge appended new_string after disk, causing ## Delegation Timeline
    // on disk to appear after the re-stated ## Plan in new_string → false denial.
    it("In-place ## Plan edit with downstream sections on disk — ALLOW (naive-merge regression)", async () => {
      const logFile = path.join(logDir, "inplace_plan.md");
      fs.writeFileSync(
        logFile,
        "## Plan\n\nold plan\n\n## Delegation Timeline\n\n| T | A |\n\n## Files Modified\n\nfoo\n",
      );
      await loadHook();
      const result = await _capturedHandler(
        editEvent(logFile, "## Plan\n\nold plan", "## Plan\n\nupdated plan"),
      );
      assert.ok(allowed(result), `Expected ALLOW, got: ${JSON.stringify(result)}`);
    });

    // ── Test 20: Reviewer re-states ## reviewer-phoenix Section header at EOF → ALLOW ──
    // Regression: naive merge appended new_string (with reviewer header) after disk content
    // that already had reviewer header → false denial. Result-simulation replaces correctly.
    it("Reviewer re-states section header when replacing placeholder — ALLOW (naive-merge regression)", async () => {
      const logFile = path.join(logDir, "reviewer_restate.md");
      fs.writeFileSync(
        logFile,
        "## Plan\n\nplan\n\n## Files Modified\n\nfoo\n\n## developer-phoenix-backend Section\n\nbody\n\n## reviewer-phoenix Section\n\n<placeholder>\n",
      );
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
  },
);
