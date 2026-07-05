/**
 * Tests for env-var-sample-consistency hook (session_shutdown, observe-only).
 * Mirrors cases from env-var-sample-consistency_test.sh.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execSync } from "node:child_process";

describe("env-var-sample-consistency", { concurrency: false }, () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  function makeRepo(prefix: string): string {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
    execSync("git init -q", { cwd: tmpDir });
    execSync("git config user.email t@t", { cwd: tmpDir });
    execSync("git config user.name t", { cwd: tmpDir });
    execSync("git config commit.gpgsign false", { cwd: tmpDir });
    execSync("git checkout -q -b main", { cwd: tmpDir });
    return tmpDir;
  }

  async function runHook(
    cwd: string,
    agentType: string,
  ): Promise<{ stderr: string }> {
    process.env["AGENT_TYPE"] = agentType;
    process.env["CWD"] = cwd;
    const modPath = "../env-var-sample-consistency";
    // Bust the module cache is unnecessary — register() re-reads env at
    // call time via parseAgentType()/process.env["CWD"].
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

  it("non-developer agent is not gated (no warning)", async () => {
    const tmpDir = makeRepo("env-var-sample-nondev-");
    try {
      fs.writeFileSync(
        path.join(tmpDir, "runtime.exs"),
        'config :app, key: System.get_env("EXISTING_VAR")\n',
      );
      execSync("git add runtime.exs", { cwd: tmpDir });
      execSync("git commit -q -m init", { cwd: tmpDir });
      fs.writeFileSync(
        path.join(tmpDir, "runtime.exs"),
        'config :app, key: System.get_env("EXISTING_VAR")\nconfig :app, k2: System.get_env("NEW_VAR")\n',
      );
      const { stderr } = await runHook(tmpDir, "committer");
      assert.equal(stderr, "");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("developer with undocumented working-tree var warns", async () => {
    const tmpDir = makeRepo("env-var-sample-warn-");
    try {
      fs.writeFileSync(path.join(tmpDir, "runtime.exs"), "config :app, key: 1\n");
      execSync("git add runtime.exs", { cwd: tmpDir });
      execSync("git commit -q -m init", { cwd: tmpDir });
      fs.writeFileSync(
        path.join(tmpDir, "runtime.exs"),
        'config :app, key: System.get_env("NEW_VAR")\n',
      );
      const { stderr } = await runHook(tmpDir, "developer-phoenix-backend");
      assert.ok(
        stderr.includes("NEW_VAR"),
        `expected warning mentioning NEW_VAR, got: ${stderr}`,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("developer with both samples declaring the new var does not warn", async () => {
    const tmpDir = makeRepo("env-var-sample-documented-");
    try {
      fs.writeFileSync(path.join(tmpDir, "runtime.exs"), "config :app, key: 1\n");
      fs.writeFileSync(path.join(tmpDir, ".env.sample"), "");
      fs.writeFileSync(path.join(tmpDir, ".env.prod.sample"), "");
      execSync("git add runtime.exs .env.sample .env.prod.sample", {
        cwd: tmpDir,
      });
      execSync("git commit -q -m init", { cwd: tmpDir });
      fs.writeFileSync(
        path.join(tmpDir, "runtime.exs"),
        'config :app, key: System.get_env("NEW_VAR")\n',
      );
      fs.writeFileSync(path.join(tmpDir, ".env.sample"), "export NEW_VAR=\n");
      fs.writeFileSync(path.join(tmpDir, ".env.prod.sample"), "NEW_VAR=\n");
      const { stderr } = await runHook(tmpDir, "developer-phoenix-frontend");
      assert.equal(stderr, "");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("argless System.get_env() does not warn", async () => {
    const tmpDir = makeRepo("env-var-sample-argless-");
    try {
      fs.writeFileSync(path.join(tmpDir, "runtime.exs"), "config :app, key: 1\n");
      execSync("git add runtime.exs", { cwd: tmpDir });
      execSync("git commit -q -m init", { cwd: tmpDir });
      fs.writeFileSync(
        path.join(tmpDir, "runtime.exs"),
        "config :app, key: System.get_env()\n",
      );
      const { stderr } = await runHook(tmpDir, "developer-phoenix-backend");
      assert.equal(stderr, "");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("already-documented literal var read does not warn", async () => {
    const tmpDir = makeRepo("env-var-sample-existing-");
    try {
      fs.writeFileSync(path.join(tmpDir, "runtime.exs"), "config :app, key: 1\n");
      fs.writeFileSync(path.join(tmpDir, ".env.sample"), "export EXISTING_VAR=\n");
      fs.writeFileSync(path.join(tmpDir, ".env.prod.sample"), "EXISTING_VAR=\n");
      execSync("git add runtime.exs .env.sample .env.prod.sample", {
        cwd: tmpDir,
      });
      execSync("git commit -q -m init", { cwd: tmpDir });
      fs.writeFileSync(
        path.join(tmpDir, "runtime.exs"),
        'config :app, key: System.get_env("EXISTING_VAR")\nconfig :app, other: 1\n',
      );
      const { stderr } = await runHook(tmpDir, "developer-phoenix-backend");
      assert.equal(stderr, "");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("removed-only System.get_env line does not warn", async () => {
    const tmpDir = makeRepo("env-var-sample-removed-");
    try {
      fs.writeFileSync(
        path.join(tmpDir, "runtime.exs"),
        'config :app, key: System.get_env("GONE_VAR")\n',
      );
      execSync("git add runtime.exs", { cwd: tmpDir });
      execSync("git commit -q -m init", { cwd: tmpDir });
      fs.writeFileSync(path.join(tmpDir, "runtime.exs"), "");
      const { stderr } = await runHook(tmpDir, "developer-phoenix-backend");
      assert.equal(stderr, "");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("unstaged working-tree edit with undocumented var still warns", async () => {
    // Proves the working-tree source (`git diff HEAD`), not a staged-only
    // diff — no `git add` is called on the edit below.
    const tmpDir = makeRepo("env-var-sample-unstaged-");
    try {
      fs.writeFileSync(path.join(tmpDir, "runtime.exs"), "config :app, key: 1\n");
      execSync("git add runtime.exs", { cwd: tmpDir });
      execSync("git commit -q -m init", { cwd: tmpDir });
      fs.writeFileSync(
        path.join(tmpDir, "runtime.exs"),
        'config :app, key: System.get_env("UNSTAGED_VAR")\n',
      );
      const { stderr } = await runHook(tmpDir, "developer-phoenix-backend");
      assert.ok(
        stderr.includes("UNSTAGED_VAR"),
        `expected warning mentioning UNSTAGED_VAR, got: ${stderr}`,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("pattern in a non-.exs file is not scanned (scoping regression guard)", async () => {
    // A test-authoring file's string literal (e.g. a shell/TS fixture that
    // constructs `System.get_env("X")` text) must never trip this hook —
    // only *.ex/*.exs diffs are scanned.
    const tmpDir = makeRepo("env-var-sample-non-exs-");
    try {
      fs.writeFileSync(path.join(tmpDir, "script.sh"), "echo hello\n");
      execSync("git add script.sh", { cwd: tmpDir });
      execSync("git commit -q -m init", { cwd: tmpDir });
      fs.writeFileSync(
        path.join(tmpDir, "script.sh"),
        'echo hello\necho \'System.get_env("SCRIPT_ONLY_VAR")\'\n',
      );
      const { stderr } = await runHook(tmpDir, "developer-phoenix-backend");
      assert.equal(stderr, "");
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
