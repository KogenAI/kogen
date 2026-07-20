/**
 * Tests for pitch-format-validator hook.
 * Mirrors cases from pitch-format-validator_test.sh.
 * Note: Pi session_shutdown is observe-only — warns to stderr, cannot block.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("pitch-format-validator", { concurrency: false }, () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "pitch-format-validator-test-"),
    );
    fs.mkdirSync(path.join(tmpDir, "codegen", "pitches", "ready"), {
      recursive: true,
    });
    process.env["CWD"] = tmpDir;
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["CWD"];
    delete process.env["PI_ROLE"];
    delete process.env["CLAUDE_ROLE"];
  });

  function writePitch(content: string): void {
    fs.writeFileSync(
      path.join(tmpDir, "codegen", "pitches", "ready", "my-feature.md"),
      content,
    );
  }

  async function runHook(role = "shape"): Promise<string> {
    process.env["PI_ROLE"] = role;

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../pitch-format-validator");
    mod.register(
      localMockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );

    let stderrOutput = "";
    const origStderrWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (s: string) => {
      stderrOutput += s;
      return true;
    };
    try {
      await capturedHandler!({
        toolName: "session_shutdown",
        toolCallId: "test-id",
        input: {},
      });
    } finally {
      process.stderr.write = origStderrWrite;
    }
    return stderrOutput;
  }

  // Skip: role not in scope
  it("skips when role is build (not shape/refactor/ops)", async () => {
    writePitch("> Status: FOO\n");
    const stderr = await runHook("build");
    assert.ok(!stderr.includes("pitch-format-validator"), "expected no warning");
  });

  // Skip: no pitch found
  it("skips when no pitch exists", async () => {
    const stderr = await runHook("shape");
    assert.ok(!stderr.includes("pitch-format-validator"), "expected no warning");
  });

  // Skip: pitch has no ## Questions
  it("skips validation when no ## Questions block present", async () => {
    writePitch("# My Pitch\n\nSome content without questions.\n");
    const stderr = await runHook("shape");
    assert.ok(!stderr.includes("pitch-format-validator"), "expected no warning");
  });

  // (a) Status validation
  it("warns on invalid > Status: value", async () => {
    writePitch("> Status: FOO\n\nSome content.\n");
    const stderr = await runHook("shape");
    assert.ok(stderr.includes("pitch-format-validator"), "expected warning");
    assert.ok(stderr.includes("FOO"));
  });

  it("does not warn on valid > Status: SKELETON", async () => {
    writePitch("> Status: SKELETON\n\nSome content.\n");
    const stderr = await runHook("shape");
    assert.ok(!stderr.includes("invalid"), "expected no status warning");
  });

  it("does not warn on valid > Status: SHAPING", async () => {
    writePitch("> Status: SHAPING\n\nSome content.\n");
    const stderr = await runHook("shape");
    assert.ok(!stderr.includes("invalid"), "expected no status warning");
  });

  it("does not warn on valid > Status: SHAPED", async () => {
    writePitch("> Status: SHAPED\n\nSome content.\n");
    const stderr = await runHook("shape");
    assert.ok(!stderr.includes("invalid"), "expected no status warning");
  });

  // (a) frontmatter status validation (dual-read)
  it("warns on invalid frontmatter status: value", async () => {
    writePitch("---\nstatus: FOO\nblocks_on: []\n---\n\nSome content.\n");
    const stderr = await runHook("shape");
    assert.ok(stderr.includes("pitch-format-validator"), "expected warning");
    assert.ok(stderr.includes("FOO"));
  });

  it("does not warn on valid frontmatter status: SHAPED", async () => {
    writePitch("---\nstatus: SHAPED\nblocks_on: []\n---\n\nSome content.\n");
    const stderr = await runHook("shape");
    assert.ok(!stderr.includes("invalid"), "expected no status warning");
  });

  it("frontmatter status: is inert to ## Questions/## Answers extraction", async () => {
    const content = [
      "---",
      "status: SHAPED",
      "blocks_on: []",
      "---",
      "",
      "## Questions",
      "",
      "### Q1: Which approach?",
      "",
      "- **a)** Option A",
      "- **b)** Option B",
      "",
    ].join("\n");
    writePitch(content);
    const stderr = await runHook("shape");
    assert.ok(!stderr.includes("pitch-format-validator"), "expected no warning");
  });

  it("frontmatter present + malformed Questions still warns (Q/A validation still runs)", async () => {
    const content = [
      "---",
      "status: SHAPED",
      "blocks_on: []",
      "---",
      "",
      "## Questions",
      "",
      "Just some text without Q headings.",
      "",
    ].join("\n");
    writePitch(content);
    const stderr = await runHook("shape");
    assert.ok(stderr.includes("no `### Q<n>:`"), "expected Q heading warning");
  });

  // (b) ## Questions validation
  it("warns when ## Questions has no ### Q<n>: headings", async () => {
    writePitch("## Questions\n\nJust some text without Q headings.\n");
    const stderr = await runHook("shape");
    assert.ok(stderr.includes("no `### Q<n>:`"), "expected Q heading warning");
  });

  it("warns when ### Q<n>: has fewer than 2 option bullets", async () => {
    const content = [
      "## Questions",
      "",
      "### Q1: Which approach?",
      "",
      "- **a)** Option A",
      "",
    ].join("\n");
    writePitch(content);
    const stderr = await runHook("shape");
    assert.ok(
      stderr.includes("fewer than 2 option bullets"),
      "expected bullet count warning",
    );
  });

  it("does not warn when ### Q<n>: has 2+ option bullets", async () => {
    const content = [
      "## Questions",
      "",
      "### Q1: Which approach?",
      "",
      "- **a)** Option A",
      "- **b)** Option B",
      "",
    ].join("\n");
    writePitch(content);
    const stderr = await runHook("shape");
    assert.ok(!stderr.includes("fewer than 2"), "expected no bullet warning");
  });

  // (c) ## Answers orphan check
  it("warns when ## Answers has stray Q-ref not in ## Questions", async () => {
    const content = [
      "## Questions",
      "",
      "### Q1: Which approach?",
      "",
      "- **a)** Option A",
      "- **b)** Option B",
      "",
      "## Answers",
      "",
      "### Q2: Stray answer",
      "",
      "Choice: b",
      "",
    ].join("\n");
    writePitch(content);
    const stderr = await runHook("shape");
    assert.ok(stderr.includes("Q2"), "expected stray answer warning");
  });

  it("does not warn when ## Answers Q-refs match ## Questions", async () => {
    const content = [
      "## Questions",
      "",
      "### Q1: Which approach?",
      "",
      "- **a)** Option A",
      "- **b)** Option B",
      "",
      "## Answers",
      "",
      "### Q1: Chosen answer",
      "",
      "Choice: a",
      "",
    ].join("\n");
    writePitch(content);
    const stderr = await runHook("shape");
    assert.ok(!stderr.includes("stray answer"), "expected no answer warning");
  });

  // Role bypass: ops and refactor also trigger
  it("enforces for role=ops", async () => {
    writePitch("> Status: BAD\n");
    const stderr = await runHook("ops");
    assert.ok(stderr.includes("pitch-format-validator"), "expected warning");
  });

  it("enforces for role=refactor", async () => {
    writePitch("> Status: BAD\n");
    const stderr = await runHook("refactor");
    assert.ok(stderr.includes("pitch-format-validator"), "expected warning");
  });

  // (d) waives: frontmatter registry validation
  function writeRegistryFixture(): void {
    fs.mkdirSync(path.join(tmpDir, "shared", "enforcement"), {
      recursive: true,
    });
    fs.writeFileSync(
      path.join(tmpDir, "shared", "enforcement", "registry.yaml"),
      [
        "- kind: registration",
        "  id: prompt-budget-writer-only",
        "  event: PreToolUse",
        '  tool_guard: "Bash|Edit|Write|MultiEdit"',
        "  surface: user_global",
        "  signal: AGENT_TYPE",
        '  role: "*"',
        "  harnesses: all",
        "  waivable: true",
        "  rationale: fixture entry",
        "",
        "- kind: registration",
        "  id: session-log-writer-only",
        "  event: PreToolUse",
        '  tool_guard: "Bash|Edit|Write|MultiEdit"',
        "  surface: user_global",
        "  signal: AGENT_TYPE",
        '  role: "*"',
        "  harnesses: all",
        "",
      ].join("\n"),
    );
  }

  it("warns on waives: naming an unknown registry id", async () => {
    writeRegistryFixture();
    writePitch(
      "---\nstatus: SHAPED\nwaives: [no-such-hook]\n---\n\nSome content.\n",
    );
    const stderr = await runHook("shape");
    assert.ok(stderr.includes("no-such-hook"), "expected waives warning");
  });

  it("warns on waives: naming a real id without waivable: true", async () => {
    writeRegistryFixture();
    writePitch(
      "---\nstatus: SHAPED\nwaives: [session-log-writer-only]\n---\n\nSome content.\n",
    );
    const stderr = await runHook("shape");
    assert.ok(
      stderr.includes("session-log-writer-only"),
      "expected waives warning",
    );
  });

  it("does not warn on waives: naming a real waivable: true id", async () => {
    writeRegistryFixture();
    writePitch(
      "---\nstatus: SHAPED\nwaives: [prompt-budget-writer-only]\n---\n\nSome content.\n",
    );
    const stderr = await runHook("shape");
    assert.ok(
      !stderr.includes("waives:"),
      "expected no waives warning",
    );
  });

  it("does not warn when no waives: line is present", async () => {
    writeRegistryFixture();
    writePitch("---\nstatus: SHAPED\n---\n\nSome content.\n");
    const stderr = await runHook("shape");
    assert.ok(
      !stderr.includes("waives:"),
      "expected no waives warning",
    );
  });

  // Returns null (observe-only)
  it("never returns block result (observe-only)", async () => {
    writePitch("> Status: FOO\n");
    process.env["PI_ROLE"] = "shape";

    let capturedHandler: (event: unknown) => Promise<unknown>;
    const localMockPi = {
      on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
        capturedHandler = handler;
      },
    };

    const mod = await import("../pitch-format-validator");
    mod.register(
      localMockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );

    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (_s: string) => true;
    let result: unknown;
    try {
      result = await capturedHandler!({
        toolName: "session_shutdown",
        toolCallId: "test-id",
        input: {},
      });
    } finally {
      process.stderr.write = origWrite;
    }
    assert.ok(
      result == null || (result as { block?: boolean }).block !== true,
      "Pi session_shutdown must not block",
    );
  });
});
