/**
 * Tests for stripHeredocBodies(), splitCommandGroups(), and
 * isCodegenLogWrite() in lib/hook-helpers.ts — the invocation-anchored
 * codegen-log exemption predicate. Mirrors the corresponding cases in
 * hooks-lib_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  stripHeredocBodies,
  splitCommandGroups,
  isCodegenLogWrite,
} from "../../lib/hook-helpers";

describe("stripHeredocBodies", () => {
  it("bare <<EOF — opener kept, body+terminator dropped", () => {
    const cmd =
      "codegen-log section developer --slug foo <<EOF\nbody with git commit\nEOF";
    assert.equal(
      stripHeredocBodies(cmd),
      "codegen-log section developer --slug foo <<EOF",
    );
  });

  it("quoted <<'EOF' — opener kept, body+terminator dropped", () => {
    const cmd =
      "codegen-log section developer --slug foo <<'EOF'\nbody with git commit\nEOF";
    assert.equal(
      stripHeredocBodies(cmd),
      "codegen-log section developer --slug foo <<'EOF'",
    );
  });

  it('double-quoted <<"EOF" — opener kept, body+terminator dropped', () => {
    const cmd =
      'codegen-log section developer --slug foo <<"EOF"\nbody with git commit\nEOF';
    assert.equal(
      stripHeredocBodies(cmd),
      'codegen-log section developer --slug foo <<"EOF"',
    );
  });

  it("tab-suppressed <<-EOF — opener kept, body+terminator dropped", () => {
    const cmd =
      "codegen-log section developer --slug foo <<-EOF\n\tbody with git commit\nEOF";
    assert.equal(
      stripHeredocBodies(cmd),
      "codegen-log section developer --slug foo <<-EOF",
    );
  });

  it("no heredoc present — unchanged", () => {
    assert.equal(stripHeredocBodies("git commit -m foo"), "git commit -m foo");
  });
});

describe("splitCommandGroups — hard-boundary split, pipe stays intact", () => {
  it("a pipe chain is ONE group", () => {
    assert.deepEqual(splitCommandGroups("printf %s x | codegen-log section"), [
      "printf %s x | codegen-log section",
    ]);
  });

  it("&& splits into two groups", () => {
    assert.deepEqual(splitCommandGroups("codegen-log init && git commit"), [
      "codegen-log init ",
      " git commit",
    ]);
  });

  it("unbalanced quote fails closed (null)", () => {
    assert.equal(splitCommandGroups('echo "unterminated'), null);
  });
});

describe("isCodegenLogWrite — invocation-anchored, not spelling-anchored", () => {
  it("piped body — true (real invocation)", () => {
    assert.equal(
      isCodegenLogWrite(
        'printf %s "$body" | codegen-log section developer --slug foo',
      ),
      true,
    );
  });

  it("leading token — true", () => {
    assert.equal(
      isCodegenLogWrite("codegen-log section developer --slug foo"),
      true,
    );
  });

  it("path-prefixed — true", () => {
    assert.equal(
      isCodegenLogWrite("./codegen-log section developer --slug foo"),
      true,
    );
  });

  it("heredoc-fed body — true", () => {
    const cmd =
      "codegen-log section developer --slug foo <<EOF\nbody mentioning git commit\nEOF";
    assert.equal(isCodegenLogWrite(cmd), true);
  });

  it("spelling-only in commit message — false (the live bypass this fixes)", () => {
    assert.equal(
      isCodegenLogWrite(
        'git add -A && git commit -m "mentions codegen-log here"',
      ),
      false,
    );
  });

  it("bare git commit, no token — false", () => {
    assert.equal(isCodegenLogWrite("git commit -m foo"), false);
  });

  it("chained codegen-log && git commit — false (real commit in the chain)", () => {
    assert.equal(
      isCodegenLogWrite("codegen-log append developer --slug foo && git commit -m x"),
      false,
    );
  });

  it("chained echo-redirect && codegen-log — false (two groups, real write)", () => {
    assert.equal(
      isCodegenLogWrite(
        "echo hi > codegen/logging/x.jsonl && codegen-log init --slug foo",
      ),
      false,
    );
  });
});
