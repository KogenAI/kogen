/**
 * Tests for no-interactive-beam hook.
 * Mirrors cases from no-interactive-beam_test.sh.
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";

describe("no-interactive-beam", { concurrency: false }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(toolName: string, command: string, claudeRole = "") {
    process.env["CLAUDE_ROLE"] = claudeRole;
    delete process.env["PI_ROLE"];

    const { register } = await import("../no-interactive-beam");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({ toolName, toolCallId: "test-id", input: { command } });
  }

  beforeEach(() => {
    delete process.env["CLAUDE_ROLE"];
    delete process.env["PI_ROLE"];
  });

  afterEach(() => {
    delete process.env["CLAUDE_ROLE"];
    delete process.env["PI_ROLE"];
  });

  it("blocks bare erl -eval (no -noshell)", async () => {
    const result = await runHook("bash", "erl -eval 'io:format(\"hi\")'");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks bare erl -run (no -noshell)", async () => {
    const result = await runHook("bash", "erl -run foo bar");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("blocks bare interactive iex", async () => {
    const result = await runHook("bash", "iex -S mix");
    assert.ok((result as { block?: boolean }).block === true);
  });

  it("allows erl -noshell -eval ... -s init stop", async () => {
    const result = await runHook(
      "bash",
      "erl -noshell -eval 'io:format(\"hi\")' -s init stop",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows erl -noshell -eval ... halt()", async () => {
    const result = await runHook(
      "bash",
      "erl -noshell -eval 'io:format(\"~s\",[erlang:system_info(otp_release)]),halt().'",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows elixir -e", async () => {
    const result = await runHook("bash", "elixir -e 'IO.puts(1+1)'");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows iex -e", async () => {
    const result = await runHook("bash", "iex -e 'IO.puts(1)'");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows iex --eval", async () => {
    const result = await runHook("bash", "iex --eval 'IO.puts(1)'");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows make test", async () => {
    const result = await runHook("bash", "make test");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows mix compile", async () => {
    const result = await runHook("bash", "mix compile");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows non-bash tool", async () => {
    const result = await runHook("read", "erl -eval 'x'");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows codegen-log write narrating erl -eval", async () => {
    const result = await runHook(
      "bash",
      "codegen-log section --slug test --body @- <<EOF\n## developer-phoenix-backend Section\nSelf-corrected erl -eval to -noshell form.\nEOF",
    );
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("allows quoted erl -eval mention (grep arg)", async () => {
    const result = await runHook("bash", 'grep -n "erl -eval" notes.md');
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("bypasses when CLAUDE_ROLE=debug", async () => {
    const result = await runHook("bash", "erl -eval 'x'", "debug");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("bypasses when CLAUDE_ROLE=shape", async () => {
    const result = await runHook("bash", "erl -eval 'x'", "shape");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("bypasses when CLAUDE_ROLE=ops", async () => {
    const result = await runHook("bash", "erl -eval 'x'", "ops");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("still blocks real unquoted erl -eval (sanity)", async () => {
    const result = await runHook("bash", "erl -eval 'io:format(\"x\")'");
    assert.ok((result as { block?: boolean }).block === true);
  });
});
