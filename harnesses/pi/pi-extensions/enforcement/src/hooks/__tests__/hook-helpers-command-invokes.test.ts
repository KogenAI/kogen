/**
 * Tests for commandWordOfSegment(), segmentArgvOf(), and commandInvokes()
 * in lib/hook-helpers.ts — the command-POSITION-aware match primitive.
 * Mirrors the command_invokes cases in hooks-lib_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  commandWordOfSegment,
  commandInvokes,
  stripGitGlobalOpts,
  splitCommandSegments,
} from "../../lib/hook-helpers";

describe("commandWordOfSegment", () => {
  it("resolves the plain command word", () => {
    assert.equal(commandWordOfSegment("rm -rf /tmp/x"), "rm");
  });

  it("strips a leading env assignment", () => {
    assert.equal(commandWordOfSegment("FOO=1 rm -rf /tmp/x"), "rm");
  });

  it("strips multiple wrapper prefixes", () => {
    assert.equal(
      commandWordOfSegment("sudo env FOO=1 exec rm -rf /tmp/x"),
      "rm",
    );
  });

  it("resolves blank segment to empty string", () => {
    assert.equal(commandWordOfSegment("   "), "");
  });
});

describe("commandInvokes — command-POSITION-aware match (mention vs invocation)", () => {
  it("matches a real kill invocation", () => {
    assert.equal(commandInvokes("kill 123", /^(kill|pkill|killall)$/), true);
  });

  it("matches a real rm -rf invocation", () => {
    assert.equal(
      commandInvokes(
        "rm -rf /tmp/x",
        /^rm$/,
        /(^|\s)-[a-zA-Z]*[rR][a-zA-Z]*(\s|$)|--recursive\b/,
      ),
      true,
    );
  });

  it("matches a real git push invocation", () => {
    assert.equal(
      commandInvokes(
        stripGitGlobalOpts("git push origin main"),
        /^git$/,
        /^push\b/,
      ),
      true,
    );
  });

  it("recurses into an inline bash -c payload", () => {
    assert.equal(
      commandInvokes("bash -c 'kill 123'", /^(kill|pkill|killall)$/),
      true,
    );
  });

  it("matches a wrapped rm -rf after prefix strip", () => {
    assert.equal(
      commandInvokes(
        "sudo env FOO=1 exec rm -rf /tmp/x",
        /^rm$/,
        /(^|\s)-[a-zA-Z]*[rR][a-zA-Z]*(\s|$)/,
      ),
      true,
    );
  });

  it("normalizes git -C <path> push via stripGitGlobalOpts first", () => {
    assert.equal(
      commandInvokes(
        stripGitGlobalOpts("git -C /tmp/x push"),
        /^git$/,
        /^push\b/,
      ),
      true,
    );
  });

  it("does NOT match a mention inside a grep pattern", () => {
    assert.equal(
      commandInvokes("grep -c kill foo.sh", /^(kill|pkill|killall)$/),
      false,
    );
  });

  it("does NOT match a mention inside an echo string", () => {
    assert.equal(
      commandInvokes("echo 'tree-kill teardown'", /^(kill|pkill|killall)$/),
      false,
    );
  });

  it("does NOT match a mention of 'rm -rf' inside a grep pattern", () => {
    assert.equal(
      commandInvokes(
        "grep -rn 'rm -rf x' notes.md",
        /^rm$/,
        /(^|\s)-[a-zA-Z]*[rR][a-zA-Z]*(\s|$)/,
      ),
      false,
    );
  });

  it("does NOT match a mention of 'git push' inside a grep pattern", () => {
    assert.equal(
      commandInvokes("grep -n 'git push' docs.md", /^git$/, /^push\b/),
      false,
    );
  });

  it("does NOT match rm --force (no recursive flag)", () => {
    assert.equal(
      commandInvokes(
        "rm --force /tmp/foo",
        /^rm$/,
        /(^|\s)-[a-zA-Z]*[rR][a-zA-Z]*(\s|$)|--recursive\b/,
      ),
      false,
    );
  });

  it("fails CLOSED on an unbalanced quote", () => {
    assert.equal(commandInvokes("echo 'unterminated", /^(kill)$/), true);
  });

  it("matches SQL keyword case-insensitively via ci-equivalent regex flag", () => {
    assert.equal(
      commandInvokes(
        "psql $DATABASE_URL -c 'truncate table users;'",
        /^psql$/,
        /\b(TRUNCATE|DROP\s+TABLE|DELETE\s+FROM)\b/i,
      ),
      true,
    );
  });
});

describe("splitCommandSegments / commandInvokes — escaped-quote false positives (defect 1)", () => {
  it("parses (non-null) a command with an escaped dq inside a dq string", () => {
    assert.notEqual(
      splitCommandSegments('grep "a\\"b" file; echo done'),
      null,
    );
  });

  it("keeps an escaped dq inside one segment, not split early", () => {
    assert.deepEqual(splitCommandSegments('grep "a\\"b" file'), [
      'grep "a\\"b" file',
    ]);
  });

  // FP1 (live, 2026-07-17): grep -o pipeline with an escaped-quote pattern.
  it("FP1: grep -o pipeline w/ escaped quotes -> no rm invocation", () => {
    assert.equal(
      commandInvokes(
        'grep -o "{% include \\"[^\\"]*\\"" tmpl | sed -n 1p',
        /^rm$/,
      ),
      false,
    );
  });

  // FP2 (live, 2026-07-17): pipeline w/ escaped quotes, no git token.
  it("FP2: pipeline w/ escaped quotes -> no git push", () => {
    assert.equal(
      commandInvokes(
        'grep -c "a\\"b" file.txt | bash -c "cat"',
        /^git$/,
        /^push\b/,
      ),
      false,
    );
  });

  it("MINIMAL: grep with escaped dq; echo done -> no rm invocation", () => {
    assert.equal(
      commandInvokes('grep "a\\"b" file; echo done', /^rm$/),
      false,
    );
  });

  // FP4 (live from the /ready gate on this pitch).
  it('FP4: grep -n "deny \\"" <path> -> no rm invocation', () => {
    assert.equal(
      commandInvokes(
        'grep -n "deny \\"" harnesses/claude/hooks/developer-no-self-gate-reset.sh',
        /^rm$/,
      ),
      false,
    );
  });

  // FP5 (live from the /ready gate on this pitch).
  it('FP5: git grep -n "ev\\":\\"committed\\"" -- <paths> -> no rm invocation', () => {
    assert.equal(
      commandInvokes(
        'git grep -n "ev\\":\\"committed\\"" -- test_harness/lib codegen-log',
        /^rm$/,
      ),
      false,
    );
  });

  it("CONTROL: rm -rf /tmp/x still denies", () => {
    assert.equal(
      commandInvokes(
        "rm -rf /tmp/x",
        /^rm$/,
        /(^|\s)-[a-zA-Z]*[rR][a-zA-Z]*(\s|$)|--recursive\b/,
      ),
      true,
    );
  });

  it('CONTROL: rm -rf "/x\\"y" (escaped quote in arg) still denies', () => {
    assert.equal(
      commandInvokes(
        'rm -rf "/x\\"y"',
        /^rm$/,
        /(^|\s)-[a-zA-Z]*[rR][a-zA-Z]*(\s|$)|--recursive\b/,
      ),
      true,
    );
  });

  it("CONTROL: genuinely unbalanced quote still fails closed", () => {
    assert.equal(commandInvokes('echo "oops', /^(kill)$/), true);
  });
});
