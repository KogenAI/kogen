/**
 * Tests for reviewer-bash-allowlist hook.
 * Mirrors cases from reviewer-bash-allowlist_test.sh.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeBashEvent(command: string) {
  return { toolName: "bash", toolCallId: "test-id", input: { command } };
}

function makeFileEvent(toolName: "write" | "edit", file_path: string) {
  return { toolName, toolCallId: "test-id", input: { file_path } };
}

describe("reviewer-bash-allowlist", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runBashHook(command: string, agentType = "reviewer-phoenix") {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../reviewer-bash-allowlist");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeBashEvent(command));
  }

  async function runFileHook(
    toolName: "write" | "edit",
    file_path: string,
    agentType = "reviewer-phoenix",
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../reviewer-bash-allowlist");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(makeFileEvent(toolName, file_path));
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  // ── codegen-log: ALLOW (bare and piped, body prose with trigger tokens) ──

  it("allows codegen-log init for reviewer-phoenix", async () => {
    const result = await runBashHook("codegen-log init --slug demo");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows codegen-log section --role for reviewer-static", async () => {
    const result = await runBashHook(
      "codegen-log section --role reviewer-static",
      "reviewer-static",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows printf | codegen-log section --body @- for reviewer-phoenix", async () => {
    const result = await runBashHook(
      "printf '%s' \"body text\" | codegen-log section --body @-",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows codegen-log body with 'make test' prose (carve-out)", async () => {
    const result = await runBashHook(
      "printf '%s' \"Gate run: make test passed\" | codegen-log section --body @-",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows codegen-log body with 'git commit' prose (carve-out)", async () => {
    const result = await runBashHook(
      "printf '%s' \"Verified git commit -m done\" | codegen-log section --body @-",
      "reviewer-static",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows codegen-log append --role for reviewer-phoenix", async () => {
    const result = await runBashHook(
      "printf '%s' \"marker\" | codegen-log append --role reviewer-phoenix --body @-",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Safe read-only utilities: ALLOW ─────────────────────────────────────

  it("allows git diff for reviewer-phoenix", async () => {
    const result = await runBashHook("git diff");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git status for reviewer-static", async () => {
    const result = await runBashHook("git status", "reviewer-static");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git log for reviewer-phoenix", async () => {
    const result = await runBashHook("git log --oneline -5");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows git show for reviewer-phoenix", async () => {
    const result = await runBashHook("git show HEAD");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows echo | wc -c for reviewer-phoenix", async () => {
    const result = await runBashHook('echo -n "subject line" | wc -c');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows cat file for reviewer-static", async () => {
    const result = await runBashHook("cat codegen/logging/foo.md", "reviewer-static");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows ls for reviewer-phoenix", async () => {
    const result = await runBashHook("ls codegen/logging/");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── History-mutating git verbs: DENY ────────────────────────────────────

  it("blocks git commit for reviewer-phoenix", async () => {
    const result = await runBashHook('git commit -m "x"');
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git add for reviewer-static", async () => {
    const result = await runBashHook("git add -A", "reviewer-static");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks git checkout for reviewer-phoenix", async () => {
    const result = await runBashHook("git checkout main");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Build/test/package-manager commands: DENY ───────────────────────────

  it("blocks mix test for reviewer-phoenix", async () => {
    const result = await runBashHook("mix test path/to/test.exs");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks make test for reviewer-static", async () => {
    const result = await runBashHook("make test", "reviewer-static");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks npm run build for reviewer-phoenix", async () => {
    const result = await runBashHook("npm run build");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks node script.js for reviewer-static", async () => {
    const result = await runBashHook("node script.js", "reviewer-static");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Arbitrary commands: DENY ────────────────────────────────────────────

  it("blocks rm -rf for reviewer-phoenix", async () => {
    const result = await runBashHook("rm -rf /tmp/foo");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks curl for reviewer-static", async () => {
    const result = await runBashHook("curl https://example.com", "reviewer-static");
    assert.ok((result as { block?: boolean }).block === true);
  });

  // ── Pass-through: non-reviewer agents ───────────────────────────────────

  it("passes through make test for non-reviewer (developer)", async () => {
    const result = await runBashHook("make test", "developer-phoenix-backend");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("passes through arbitrary curl for non-reviewer (developer)", async () => {
    const result = await runBashHook(
      "curl https://example.com",
      "developer-phoenix-backend",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  // ── Pass-through: non-Bash tools ────────────────────────────────────────

  it("passes through Write tool for reviewer-phoenix (different hook's job)", async () => {
    const result = await runFileHook("write", "lib/foo.ex");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});
