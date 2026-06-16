/**
 * Tests for static-site-build-check hook.
 * Mirrors cases from static-site-build-check_test.sh.
 * Note: Pi session_shutdown event.
 */

import { describe, it, beforeEach, mock } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("static-site-build-check", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    agentType: string,
    cwd: string,
    stop_hook_active = false,
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../static-site-build-check");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "session_shutdown",
      toolCallId: "test-id",
      input: { cwd, stop_hook_active },
      agentType,
    });
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("stop_hook_active=true short-circuits (no block)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ssbc-test-"));
    try {
      const result = await runHook("developer-static", tmpDir, true);
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("non-static-site agent_type is no-op (no block)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ssbc-test-"));
    try {
      const result = await runHook("developer-phoenix-backend", tmpDir);
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("missing package.json is non-fatal (Pi observe-only)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ssbc-nopkg-"));
    try {
      const result = await runHook("developer-static", tmpDir);
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
      );
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});

// ── Render-check stub tests ──────────────────────────────────────────────────
// These tests mock execSync to control render-check.js output without needing
// a real browser. Verifies the Pi hook surfaces FAIL to stderr and is non-fatal
// for INCONCLUSIVE.

describe("static-site-build-check render-check integration", () => {
  it("render FAIL surfaces to stderr", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ssbc-render-"));
    const stderrMessages: string[] = [];
    const origStderrWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (msg: string | Uint8Array) => {
      stderrMessages.push(typeof msg === "string" ? msg : msg.toString());
      return true;
    };

    try {
      // Write a package.json with build script so the hook proceeds to render check.
      fs.writeFileSync(
        path.join(tmpDir, "package.json"),
        JSON.stringify({
          scripts: {
            build: "echo built",
            serve: "python3 -u -m http.server --directory public 0",
          },
        }),
      );
      // Makefile with ci: target so make ci succeeds in the fixture.
      fs.writeFileSync(path.join(tmpDir, "Makefile"), "ci:\n\t@true\n");
      // Create output dir so render check is attempted.
      fs.mkdirSync(path.join(tmpDir, "public"), { recursive: true });
      fs.writeFileSync(
        path.join(tmpDir, "public", "index.html"),
        "<html><body></body></html>",
      );

      // Create a fake render-check.js that emits a FAIL verdict.
      const fakeRenderCheck = path.join(tmpDir, "render-check.js");
      fs.writeFileSync(
        fakeRenderCheck,
        `process.stdout.write("RENDER_VERDICT=FAIL:empty-dom\\n");\n`,
      );

      // Point CODEGEN_DIR at a structure where render-check.js will be found.
      const fakeCodegenDir = tmpDir;
      const hooksLibDir = path.join(
        fakeCodegenDir,
        "harnesses",
        "claude",
        "hooks",
        "lib",
      );
      fs.mkdirSync(hooksLibDir, { recursive: true });
      fs.copyFileSync(
        fakeRenderCheck,
        path.join(hooksLibDir, "render-check.js"),
      );

      process.env["AGENT_TYPE"] = "developer-static";
      process.env["CODEGEN_DIR"] = fakeCodegenDir;

      // Import fresh module — clear module cache for re-import.
      const { register } = await import("../static-site-build-check");
      let capturedHandler: (event: unknown) => Promise<unknown>;
      const mockPi = {
        on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
          capturedHandler = handler;
        },
      };
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      await capturedHandler!({
        toolName: "session_shutdown",
        toolCallId: "test",
        input: { cwd: tmpDir },
        agentType: "developer-static",
      });

      const hasFail = stderrMessages.some(
        (m) => m.includes("render FAILED") || m.includes("empty-dom"),
      );
      // Non-blocking: result doesn't throw.
      // Stderr contains the failure reason.
      assert.ok(
        hasFail,
        `expected render FAILED in stderr, got: ${stderrMessages.join("")}`,
      );
    } finally {
      process.stderr.write = origStderrWrite;
      delete process.env["CODEGEN_DIR"];
      delete process.env["AGENT_TYPE"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("render INCONCLUSIVE browser-not-installed is non-fatal (no stderr fail)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ssbc-incon-"));
    const stderrMessages: string[] = [];
    const origStderrWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (msg: string | Uint8Array) => {
      stderrMessages.push(typeof msg === "string" ? msg : msg.toString());
      return true;
    };

    try {
      fs.writeFileSync(
        path.join(tmpDir, "package.json"),
        JSON.stringify({
          scripts: {
            build: "echo built",
            serve: "python3 -u -m http.server --directory public 0",
          },
        }),
      );
      // Makefile with ci: target so make ci succeeds in the fixture.
      fs.writeFileSync(path.join(tmpDir, "Makefile"), "ci:\n\t@true\n");
      fs.mkdirSync(path.join(tmpDir, "public"), { recursive: true });
      fs.writeFileSync(
        path.join(tmpDir, "public", "index.html"),
        "<html><body><p>hi</p></body></html>",
      );

      const fakeCodegenDir = tmpDir;
      const hooksLibDir = path.join(
        fakeCodegenDir,
        "harnesses",
        "claude",
        "hooks",
        "lib",
      );
      fs.mkdirSync(hooksLibDir, { recursive: true });
      fs.writeFileSync(
        path.join(hooksLibDir, "render-check.js"),
        `process.stdout.write("RENDER_VERDICT=INCONCLUSIVE:browser-not-installed\\n");\n`,
      );

      process.env["AGENT_TYPE"] = "developer-static";
      process.env["CODEGEN_DIR"] = fakeCodegenDir;

      const { register } = await import("../static-site-build-check");
      let capturedHandler: (event: unknown) => Promise<unknown>;
      const mockPi = {
        on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
          capturedHandler = handler;
        },
      };
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      await capturedHandler!({
        toolName: "session_shutdown",
        toolCallId: "test",
        input: { cwd: tmpDir },
        agentType: "developer-static",
      });

      const hasFail = stderrMessages.some((m) => m.includes("render FAILED"));
      assert.ok(
        !hasFail,
        `unexpected render FAILED in stderr for INCONCLUSIVE: ${stderrMessages.join("")}`,
      );
    } finally {
      process.stderr.write = origStderrWrite;
      delete process.env["CODEGEN_DIR"];
      delete process.env["AGENT_TYPE"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
