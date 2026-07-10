/**
 * Tests for context-factcheck-curator-stop hook (session_shutdown, observe-only).
 * Mirrors cases from context-factcheck-curator-stop_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("context-factcheck-curator-stop", { concurrency: false }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  function makeRepo(prefix: string): string {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
    fs.writeFileSync(path.join(tmpDir, "PROJECT_CONTEXT.md"), "# platform marker\n");
    fs.mkdirSync(path.join(tmpDir, "context"));
    return tmpDir;
  }

  async function runHook(
    cwd: string,
    agentType: string,
  ): Promise<{ stderr: string }> {
    process.env["AGENT_TYPE"] = agentType;
    process.env["CWD"] = cwd;
    const modPath = "../context-factcheck-curator-stop";
    const { register } = await import(modPath);
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );

    let captured = "";
    const originalWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = ((chunk: unknown, ...args: unknown[]) => {
      captured += String(chunk);
      return true;
    }) as typeof process.stderr.write;

    try {
      await _capturedHandler({});
    } finally {
      process.stderr.write = originalWrite;
    }
    return { stderr: captured };
  }

  it("clean working-tree docs do not warn", async () => {
    const tmpDir = makeRepo("factcheck-curator-clean-");
    try {
      fs.writeFileSync(
        path.join(tmpDir, "context", "foo.md"),
        "# Foo\n\nSee `context/bar.md` for detail.\n",
      );
      fs.writeFileSync(path.join(tmpDir, "context", "bar.md"), "# Bar\n");
      const { stderr } = await runHook(tmpDir, "context-curator");
      assert.equal(stderr, "");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("non-context-curator agent is not gated (no warning)", async () => {
    const tmpDir = makeRepo("factcheck-curator-nonagent-");
    try {
      fs.writeFileSync(
        path.join(tmpDir, "context", "foo.md"),
        "# Foo\n\nSee `context/nonexistent.md` for detail.\n",
      );
      const { stderr } = await runHook(tmpDir, "committer");
      assert.equal(stderr, "");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("nonexistent path claim warns", async () => {
    const tmpDir = makeRepo("factcheck-curator-badpath-");
    try {
      fs.writeFileSync(
        path.join(tmpDir, "context", "foo.md"),
        "# Foo\n\nSee `context/nonexistent.md` for detail.\n",
      );
      const { stderr } = await runHook(tmpDir, "context-curator");
      assert.ok(
        stderr.includes("context/nonexistent.md"),
        `expected warning mentioning the missing path, got: ${stderr}`,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("count anchor mismatch warns", async () => {
    const tmpDir = makeRepo("factcheck-curator-countmismatch-");
    try {
      fs.writeFileSync(path.join(tmpDir, "context", "two.txt"), "file1\nfile2\n");
      fs.writeFileSync(
        path.join(tmpDir, "context", "foo.md"),
        "# Foo\n\n<!-- count: ls context/*.txt | wc -l -->99\n",
      );
      const { stderr } = await runHook(tmpDir, "context-curator");
      assert.ok(
        stderr.includes("but the count probe returns"),
        `expected count mismatch warning, got: ${stderr}`,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("count anchor match does not warn", async () => {
    const tmpDir = makeRepo("factcheck-curator-countmatch-");
    try {
      fs.writeFileSync(path.join(tmpDir, "context", "one.txt"), "file1\n");
      fs.writeFileSync(
        path.join(tmpDir, "context", "foo.md"),
        "# Foo\n\n<!-- count: ls context/*.txt | wc -l -->1\n",
      );
      const { stderr } = await runHook(tmpDir, "context-curator");
      assert.equal(stderr, "");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("cross-file deletion of a referenced path warns (whole-tree completeness)", async () => {
    const tmpDir = makeRepo("factcheck-curator-crossfile-");
    try {
      fs.writeFileSync(
        path.join(tmpDir, "context", "foo.md"),
        "# Foo\n\nSee `context/bar.md` for detail.\n",
      );
      fs.writeFileSync(path.join(tmpDir, "context", "bar.md"), "# Bar\n");
      // Delete the referenced file WITHOUT touching foo.md — proves the
      // scan sees the whole working tree, not just edited docs.
      fs.rmSync(path.join(tmpDir, "context", "bar.md"));
      const { stderr } = await runHook(tmpDir, "context-curator");
      assert.ok(
        stderr.includes("context/bar.md"),
        `expected warning mentioning the deleted path, got: ${stderr}`,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("Elixir source-root (lib/) fallback does not warn", async () => {
    const tmpDir = makeRepo("factcheck-curator-ex-source-root-");
    try {
      fs.mkdirSync(path.join(tmpDir, "lib", "widgetapp"), {
        recursive: true,
      });
      fs.writeFileSync(
        path.join(tmpDir, "lib", "widgetapp", "billing.ex"),
        "code\n",
      );
      fs.writeFileSync(
        path.join(tmpDir, "context", "foo.md"),
        "# Foo\n\nSee `widgetapp/billing.ex` for detail.\n",
      );
      const { stderr } = await runHook(tmpDir, "context-curator");
      assert.equal(stderr, "");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("genuinely-dead .ex path (literal, lib/, test/ all miss) warns", async () => {
    const tmpDir = makeRepo("factcheck-curator-ex-dead-");
    try {
      fs.writeFileSync(
        path.join(tmpDir, "context", "foo.md"),
        "# Foo\n\nSee `widgetapp/nope.ex` for detail.\n",
      );
      const { stderr } = await runHook(tmpDir, "context-curator");
      assert.ok(
        stderr.includes("widgetapp/nope.ex"),
        `expected warning mentioning the missing path, got: ${stderr}`,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("identifier corruption (word-internal '*') warns with token", async () => {
    const tmpDir = makeRepo("factcheck-curator-corruption-");
    try {
      fs.writeFileSync(
        path.join(tmpDir, "context", "foo.md"),
        "# Foo\n\nCall `register*route_or_live` to add a route.\n",
      );
      const { stderr } = await runHook(tmpDir, "context-curator");
      assert.ok(
        stderr.includes("register*route"),
        `expected corruption warning mentioning the token, got: ${stderr}`,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("legit '*' uses (globs, regex, bold) do not warn", async () => {
    const tmpDir = makeRepo("factcheck-curator-legit-star-");
    try {
      fs.writeFileSync(
        path.join(tmpDir, "context", "foo.md"),
        [
          "# Foo",
          "",
          "See context/*.md for domain docs.",
          "Env vars follow the OCG_* convention.",
          "Hooks named no-*.sh live under harnesses/claude/hooks/.",
          "Regex `.*` matches anything.",
          "This is **bold** text and this is *italic* text.",
          "",
        ].join("\n"),
      );
      const { stderr } = await runHook(tmpDir, "context-curator");
      assert.equal(stderr, "");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
