/**
 * Tests for phoenix-dev-gate hook.
 * Mirrors cases from phoenix-dev-gate_test.sh.
 * Note: Pi session_shutdown event; simplified behavioral tests
 * (no full filesystem/git setup needed for basic gating logic).
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function makeShutdownEvent(
  agentType: string,
  cwd = "/tmp",
  stop_hook_active = false,
) {
  return {
    toolName: "session_shutdown",
    toolCallId: "test-id",
    input: { cwd, stop_hook_active },
    agentType,
  };
}

describe("phoenix-dev-gate", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  async function runHook(
    agentType: string,
    cwd = "/tmp",
    stop_hook_active = false,
  ) {
    process.env["AGENT_TYPE"] = agentType;
    const { register } = await import("../phoenix-dev-gate");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler(
      makeShutdownEvent(agentType, cwd, stop_hook_active),
    );
  }

  beforeEach(() => {
    delete process.env["AGENT_TYPE"];
  });

  it("stop_hook_active=true short-circuits (no block)", async () => {
    const result = await runHook("developer-phoenix-backend", "/tmp", true);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("non-developer agent_type is a no-op (no block)", async () => {
    const result = await runHook("reviewer-phoenix");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("committer agent_type is a no-op (no block)", async () => {
    const result = await runHook("committer");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });
});

// ── Render-check stub tests ──────────────────────────────────────────────────
// Verifies the Pi phoenix-dev-gate hook surfaces render FAIL to stderr and
// is non-fatal for INCONCLUSIVE verdicts.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("phoenix-dev-gate render-check integration", () => {
  async function runHookWithRenderStub(
    renderVerdictLine: string,
    gatePasses = true,
    wiringVerdictLine = "WIRING_VERDICT=PASS",
  ) {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pdg-render-"));
    const stderrMessages: string[] = [];
    const origStderrWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (msg: string | Uint8Array) => {
      stderrMessages.push(typeof msg === "string" ? msg : msg.toString());
      return true;
    };

    try {
      // Set up a step log with a Gate directive.
      const loggingDir = path.join(tmpDir, "codegen", "logging");
      fs.mkdirSync(loggingDir, { recursive: true });
      const logPath = path.join(loggingDir, "20260101_000000_step1.md");
      fs.writeFileSync(
        logPath,
        `# Step\n\n## Plan\n\n**Gate**: \`${gatePasses ? "true" : "false"}\`\n`,
      );

      // Set up fake wiring-check.js and render-check.js.
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
        path.join(hooksLibDir, "wiring-check.js"),
        `process.stdout.write("${wiringVerdictLine}\\n");\n`,
      );
      fs.writeFileSync(
        path.join(hooksLibDir, "render-check.js"),
        `process.stdout.write("${renderVerdictLine}\\n");\n`,
      );

      process.env["AGENT_TYPE"] = "developer-phoenix-backend";
      process.env["CODEGEN_DIR"] = fakeCodegenDir;
      process.env["CWD"] = tmpDir;

      const { register } = await import("../phoenix-dev-gate");
      let capturedHandler: (event: unknown) => Promise<unknown>;
      const mockPi = {
        on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
          capturedHandler = handler;
        },
      };
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      await capturedHandler!(
        makeShutdownEvent("developer-phoenix-backend", tmpDir),
      );

      const logContents = fs.readFileSync(logPath, "utf8");
      return { stderrMessages, logContents };
    } finally {
      process.stderr.write = origStderrWrite;
      delete process.env["AGENT_TYPE"];
      delete process.env["CODEGEN_DIR"];
      delete process.env["CWD"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  }

  it("render PASS: ALL CLEAR with render summary in log", async () => {
    const { logContents } = await runHookWithRenderStub("RENDER_VERDICT=PASS");
    assert.ok(
      logContents.includes("ALL CLEAR"),
      `expected ALL CLEAR in log, got: ${logContents}`,
    );
    assert.ok(
      logContents.includes("DOM non-empty"),
      `expected render summary in log, got: ${logContents}`,
    );
  });

  it("render FAIL empty-dom: surfaces to stderr", async () => {
    const { stderrMessages } = await runHookWithRenderStub(
      "RENDER_VERDICT=FAIL:empty-dom",
    );
    const hasFail = stderrMessages.some(
      (m) => m.includes("render FAILED") || m.includes("empty-dom"),
    );
    assert.ok(
      hasFail,
      `expected render FAILED in stderr, got: ${stderrMessages.join("")}`,
    );
  });

  it("render FAIL unstyled: surfaces to stderr", async () => {
    const { stderrMessages } = await runHookWithRenderStub(
      "RENDER_VERDICT=FAIL:unstyled",
    );
    const hasFail = stderrMessages.some(
      (m) => m.includes("render FAILED") || m.includes("unstyled"),
    );
    assert.ok(
      hasFail,
      `expected render FAILED in stderr, got: ${stderrMessages.join("")}`,
    );
  });

  it("render INCONCLUSIVE browser-not-installed: non-fatal, ALL CLEAR kept", async () => {
    const { stderrMessages, logContents } = await runHookWithRenderStub(
      "RENDER_VERDICT=INCONCLUSIVE:browser-not-installed",
    );
    const hasFail = stderrMessages.some((m) => m.includes("render FAILED"));
    assert.ok(
      !hasFail,
      `unexpected render FAILED for INCONCLUSIVE: ${stderrMessages.join("")}`,
    );
    assert.ok(
      logContents.includes("ALL CLEAR"),
      `expected ALL CLEAR in log: ${logContents}`,
    );
  });

  it("render INCONCLUSIVE server-unready: non-fatal, ALL CLEAR kept", async () => {
    const { stderrMessages, logContents } = await runHookWithRenderStub(
      "RENDER_VERDICT=INCONCLUSIVE:server-unready",
    );
    const hasFail = stderrMessages.some((m) => m.includes("render FAILED"));
    assert.ok(
      !hasFail,
      `unexpected render FAILED for server-unready: ${stderrMessages.join("")}`,
    );
    assert.ok(
      logContents.includes("ALL CLEAR"),
      `expected ALL CLEAR in log: ${logContents}`,
    );
  });
});

// ── Checker-missing tests ────────────────────────────────────────────────────
// Verifies that when CODEGEN_DIR is set but the checker script is absent,
// the hook surfaces INCONCLUSIVE (checker-missing) in the log rather than
// silently emitting ALL CLEAR. Also verifies that CODEGEN_DIR="" (opt-out)
// keeps the silent-skip behaviour.

describe("phoenix-dev-gate checker-missing", () => {
  async function runHookWithMissingChecker(
    codegenDirSet: boolean,
    missingScript: "render" | "wiring" | "both",
  ) {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pdg-missing-"));

    try {
      const loggingDir = path.join(tmpDir, "codegen", "logging");
      fs.mkdirSync(loggingDir, { recursive: true });
      const logPath = path.join(loggingDir, "20260101_000000_step1.md");
      fs.writeFileSync(logPath, `# Step\n\n## Plan\n\n**Gate**: \`true\`\n`);

      const fakeCodegenDir = tmpDir;
      const hooksLibDir = path.join(
        fakeCodegenDir,
        "harnesses",
        "claude",
        "hooks",
        "lib",
      );
      fs.mkdirSync(hooksLibDir, { recursive: true });

      // Only write scripts that are NOT supposed to be missing.
      if (missingScript !== "wiring" && missingScript !== "both") {
        fs.writeFileSync(
          path.join(hooksLibDir, "wiring-check.js"),
          `process.stdout.write("WIRING_VERDICT=PASS\\n");\n`,
        );
      }
      if (missingScript !== "render" && missingScript !== "both") {
        fs.writeFileSync(
          path.join(hooksLibDir, "render-check.js"),
          `process.stdout.write("RENDER_VERDICT=PASS\\n");\n`,
        );
      }

      process.env["AGENT_TYPE"] = "developer-phoenix-backend";
      process.env["CWD"] = tmpDir;
      if (codegenDirSet) {
        process.env["CODEGEN_DIR"] = fakeCodegenDir;
      } else {
        delete process.env["CODEGEN_DIR"];
      }

      const { register } = await import("../phoenix-dev-gate");
      let capturedHandler: (event: unknown) => Promise<unknown>;
      const mockPi = {
        on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
          capturedHandler = handler;
        },
      };
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      await capturedHandler!(
        makeShutdownEvent("developer-phoenix-backend", tmpDir),
      );

      const logContents = fs.readFileSync(logPath, "utf8");
      return { logContents };
    } finally {
      delete process.env["AGENT_TYPE"];
      delete process.env["CODEGEN_DIR"];
      delete process.env["CWD"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  }

  it("render-check.js absent + CODEGEN_DIR set → INCONCLUSIVE (checker-missing) in log", async () => {
    const { logContents } = await runHookWithMissingChecker(true, "render");
    assert.ok(
      logContents.includes("INCONCLUSIVE") && logContents.includes("checker-missing"),
      `expected INCONCLUSIVE checker-missing in log, got: ${logContents}`,
    );
  });

  it("wiring-check.js absent + CODEGEN_DIR set → INCONCLUSIVE (checker-missing) in log", async () => {
    const { logContents } = await runHookWithMissingChecker(true, "wiring");
    assert.ok(
      logContents.includes("INCONCLUSIVE") && logContents.includes("checker-missing"),
      `expected INCONCLUSIVE checker-missing in log, got: ${logContents}`,
    );
  });

  it("CODEGEN_DIR empty (opt-out) → silent skip, ALL CLEAR kept", async () => {
    const { logContents } = await runHookWithMissingChecker(false, "both");
    assert.ok(
      logContents.includes("ALL CLEAR"),
      `expected ALL CLEAR in log for opt-out, got: ${logContents}`,
    );
    assert.ok(
      !logContents.includes("INCONCLUSIVE"),
      `unexpected INCONCLUSIVE for opt-out: ${logContents}`,
    );
  });
});

// ── Wiring-check stub tests ──────────────────────────────────────────────────
// Verifies the Pi phoenix-dev-gate hook surfaces wiring FAIL to stderr and
// downgrades the verdict; PASS adds a wiring: summary line to the log.

describe("phoenix-dev-gate wiring-check integration", () => {
  async function runHookWithWiringStub(wiringVerdictLine: string) {
    // Use the runHookWithRenderStub helper with a PASS render verdict so the
    // render step doesn't interfere with wiring assertions.
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pdg-wiring-"));
    const stderrMessages: string[] = [];
    const origStderrWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (msg: string | Uint8Array) => {
      stderrMessages.push(typeof msg === "string" ? msg : msg.toString());
      return true;
    };

    try {
      const loggingDir = path.join(tmpDir, "codegen", "logging");
      fs.mkdirSync(loggingDir, { recursive: true });
      const logPath = path.join(loggingDir, "20260101_000000_step1.md");
      fs.writeFileSync(
        logPath,
        `# Step\n\n## Plan\n\n**Gate**: \`true\`\n`,
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
      // wiring-check stub emits the requested verdict
      fs.writeFileSync(
        path.join(hooksLibDir, "wiring-check.js"),
        `process.stdout.write("${wiringVerdictLine}\\n");\n`,
      );
      // render-check stub always passes (so it doesn't interfere)
      fs.writeFileSync(
        path.join(hooksLibDir, "render-check.js"),
        `process.stdout.write("RENDER_VERDICT=PASS\\n");\n`,
      );

      process.env["AGENT_TYPE"] = "developer-phoenix-backend";
      process.env["CODEGEN_DIR"] = fakeCodegenDir;
      process.env["CWD"] = tmpDir;

      const { register } = await import("../phoenix-dev-gate");
      let capturedHandler: (event: unknown) => Promise<unknown>;
      const mockPi = {
        on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
          capturedHandler = handler;
        },
      };
      register(
        mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
      );
      await capturedHandler!(
        makeShutdownEvent("developer-phoenix-backend", tmpDir),
      );

      const logContents = fs.readFileSync(logPath, "utf8");
      return { stderrMessages, logContents };
    } finally {
      process.stderr.write = origStderrWrite;
      delete process.env["AGENT_TYPE"];
      delete process.env["CODEGEN_DIR"];
      delete process.env["CWD"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  }

  it("wiring FAIL: surfaces to stderr and downgrades verdict", async () => {
    const { stderrMessages, logContents } = await runHookWithWiringStub(
      "WIRING_VERDICT=FAIL:phx-click@#submit-btn",
    );
    const hasWiringFail = stderrMessages.some(
      (m) => m.includes("wiring FAILED") || m.includes("submit-btn"),
    );
    assert.ok(
      hasWiringFail,
      `expected wiring FAILED in stderr, got: ${stderrMessages.join("")}`,
    );
    // Verdict should be downgraded (not ALL CLEAR)
    assert.ok(
      !logContents.includes("ALL CLEAR"),
      `expected verdict downgraded from ALL CLEAR, got: ${logContents}`,
    );
    assert.ok(
      logContents.includes("FAILED") || logContents.includes("wiring check failed"),
      `expected wiring failure note in log: ${logContents}`,
    );
  });

  it("wiring PASS: adds wiring summary to log and ALL CLEAR kept", async () => {
    const { stderrMessages, logContents } = await runHookWithWiringStub(
      "WIRING_VERDICT=PASS",
    );
    const hasWiringFail = stderrMessages.some((m) =>
      m.includes("wiring FAILED"),
    );
    assert.ok(
      !hasWiringFail,
      `unexpected wiring FAILED for PASS: ${stderrMessages.join("")}`,
    );
    assert.ok(
      logContents.includes("ALL CLEAR"),
      `expected ALL CLEAR in log: ${logContents}`,
    );
    assert.ok(
      logContents.includes("wiring: PASS"),
      `expected wiring: PASS summary in log: ${logContents}`,
    );
  });

  it("wiring INCONCLUSIVE: non-fatal, ALL CLEAR kept, summary in log", async () => {
    const { stderrMessages, logContents } = await runHookWithWiringStub(
      "WIRING_VERDICT=INCONCLUSIVE:no-heex",
    );
    const hasWiringFail = stderrMessages.some((m) =>
      m.includes("wiring FAILED"),
    );
    assert.ok(
      !hasWiringFail,
      `unexpected wiring FAILED for INCONCLUSIVE: ${stderrMessages.join("")}`,
    );
    assert.ok(
      logContents.includes("ALL CLEAR"),
      `expected ALL CLEAR in log: ${logContents}`,
    );
    assert.ok(
      logContents.includes("wiring: INCONCLUSIVE"),
      `expected wiring INCONCLUSIVE note in log: ${logContents}`,
    );
  });
});
