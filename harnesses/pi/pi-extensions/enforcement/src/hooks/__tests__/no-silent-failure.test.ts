/**
 * Tests for no-silent-failure hook.
 * Mirrors cases from no-silent-failure_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

describe("no-silent-failure", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    toolName: string,
    input: Record<string, unknown>,
  ) {
    const { register } = await import("../no-silent-failure");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName,
      toolCallId: "test-id",
      input,
    });
  }

  const isDeny = (r: unknown): boolean =>
    (r as { block?: boolean } | undefined)?.block === true;
  const isAllow = (r: unknown): boolean =>
    r == null || (r as { block?: boolean }).block !== true;

  // ---- DENY cases ----

  it("denies empty catch {} (TS)", async () => {
    const result = await runHook("edit", {
      file_path: "lib/foo.ts",
      old_string: "x",
      new_string: "try { doThing(); } catch {}",
    });
    assert.ok(isDeny(result));
  });

  it("denies empty catch (e) {} (TS)", async () => {
    const result = await runHook("edit", {
      file_path: "lib/foo.ts",
      old_string: "x",
      new_string: "try { doThing(); } catch (e) {}",
    });
    assert.ok(isDeny(result));
  });

  it("denies bare except: + pass (Python)", async () => {
    const result = await runHook("write", {
      file_path: "lib/foo.py",
      content: "try:\n    do_thing()\nexcept:\n    pass\n",
    });
    assert.ok(isDeny(result));
  });

  it("denies except Exception: + pass (Python)", async () => {
    const result = await runHook("write", {
      file_path: "lib/foo.py",
      content: "try:\n    do_thing()\nexcept Exception:\n    pass\n",
    });
    assert.ok(isDeny(result));
  });

  it("denies rescue _ -> without reraise (Elixir)", async () => {
    const result = await runHook("edit", {
      file_path: "lib/foo.ex",
      old_string: "x",
      new_string: "rescue _ ->\n  :error\nend",
    });
    assert.ok(isDeny(result));
  });

  it("denies rescue e -> (named var) without reraise (Elixir)", async () => {
    const result = await runHook("edit", {
      file_path: "lib/foo.ex",
      old_string: "x",
      new_string: "rescue e ->\n  :error\nend",
    });
    assert.ok(isDeny(result));
  });

  it("denies MultiEdit concat with swallow token in edits[]", async () => {
    const result = await runHook("multiedit", {
      file_path: "lib/foo.ex",
      edits: [
        { old_string: "a", new_string: "ok" },
        { old_string: "b", new_string: "rescue _ ->\n  :error\nend" },
      ],
    });
    assert.ok(isDeny(result));
  });

  it("denies bare fail-loud-exempt with no reason", async () => {
    const result = await runHook("edit", {
      file_path: "lib/foo.ex",
      old_string: "x",
      new_string: "# fail-loud-exempt:\nrescue _ ->\n  :error\nend",
    });
    assert.ok(isDeny(result));
  });

  // ---- ALLOW cases ----

  it("allows exemption with reason", async () => {
    const result = await runHook("edit", {
      file_path: "lib/foo.ex",
      old_string: "x",
      new_string:
        "# fail-loud-exempt: sourced helper fail-open by design\nrescue _ ->\n  :error\nend",
    });
    assert.ok(isAllow(result));
  });

  it("allows {:error, reason} tagged tuple", async () => {
    const result = await runHook("edit", {
      file_path: "lib/foo.ex",
      old_string: "x",
      new_string:
        "case v do\n  {:ok, r} -> {:ok, r}\n  {:error, reason} -> {:error, reason}\nend",
    });
    assert.ok(isAllow(result));
  });

  it("allows non-empty catch", async () => {
    const result = await runHook("edit", {
      file_path: "lib/foo.ts",
      old_string: "x",
      new_string: "try { doThing(); } catch (e) { logger.error(e); }",
    });
    assert.ok(isAllow(result));
  });

  it("allows narrow reraise rescue", async () => {
    const result = await runHook("edit", {
      file_path: "lib/foo.ex",
      old_string: "x",
      new_string:
        "rescue e in File.Error ->\n  reraise e, __STACKTRACE__\nend",
    });
    assert.ok(isAllow(result));
  });

  it("allows || true (not mechanically gated)", async () => {
    const result = await runHook("edit", {
      file_path: "scripts/cleanup.sh",
      old_string: "x",
      new_string: 'rm -f "$TMP" || true',
    });
    assert.ok(isAllow(result));
  });

  it("allows non-content tool", async () => {
    const result = await runHook("bash", { command: "echo hi" });
    assert.ok(isAllow(result));
  });

  it("allows catch-all _ -> nil (class-4 removed, over-fired on doc/string content)", async () => {
    const result = await runHook("edit", {
      file_path: "lib/foo.ex",
      old_string: "x",
      new_string: "case v do\n  {:ok, r} -> r\n  _ -> nil\nend",
    });
    assert.ok(isAllow(result));
  });

  it("allows else _ -> %{} (class-4 removed)", async () => {
    const result = await runHook("edit", {
      file_path: "lib/foo.ex",
      old_string: "x",
      new_string: "else\n  _ -> %{}\nend",
    });
    assert.ok(isAllow(result));
  });
});
