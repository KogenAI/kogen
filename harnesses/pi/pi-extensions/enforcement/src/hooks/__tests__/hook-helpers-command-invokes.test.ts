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
