/**
 * transient-parity.test.ts — Hermetic bidirectional parity test.
 *
 * Asserts that Pi TRANSIENT_ERROR_PATTERNS and Bash retryable_regex stay
 * in sync: every Bash token is matched by a Pi pattern and vice versa.
 * A count-equality assertion (20 <-> 20) prevents silent drift.
 *
 * Bash source: harnesses/shared/retryable-errors.sh (single source of truth
 * for all harnesses; sourced by claude stop-resume.sh + future dispatch loops).
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { TRANSIENT_ERROR_PATTERNS } from "../stop-resume";

describe("transient-pattern parity (Bash retryable_regex <-> Pi)", () => {
  const repoRoot = path.resolve(__dirname, "../../../../../../..");
  const shPath = path.join(
    repoRoot,
    "harnesses/shared/retryable-errors.sh",
  );
  const sh = fs.readFileSync(shPath, "utf8");
  const m = sh.match(/retryable_regex='([^']*)'/);
  if (!m) throw new Error("retryable_regex not found in retryable-errors.sh");
  const bashTokens = m[1].split("|");

  it("every Bash transient token is recognized by a Pi pattern", () => {
    for (const tok of bashTokens) {
      assert.ok(
        TRANSIENT_ERROR_PATTERNS.some((p) => p.test(tok)),
        `Pi patterns miss Bash transient token: ${tok}`,
      );
    }
  });

  it("every Pi pattern matches at least one Bash transient token", () => {
    for (const p of TRANSIENT_ERROR_PATTERNS) {
      assert.ok(
        bashTokens.some((tok) => p.test(tok)),
        `Pi pattern matches no Bash token (drift): ${p}`,
      );
    }
  });

  it("token counts are equal (20 <-> 20)", () => {
    assert.equal(bashTokens.length, TRANSIENT_ERROR_PATTERNS.length);
  });

  it("new drop token present in Bash and recognized by Pi", () => {
    assert.ok(
      bashTokens.includes("Connection closed mid-response"),
      "Bash retryable_regex missing 'Connection closed mid-response'",
    );
    assert.ok(
      TRANSIENT_ERROR_PATTERNS.some((p) => p.test("Connection closed mid-response")),
      "Pi patterns miss 'Connection closed mid-response'",
    );
  });
});
