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

describe("phoenix-dev-gate sole-writer invariant", () => {
  it("source has zero raw fs.appendFileSync/fs.writeFileSync writes to the step log", () => {
    const srcPath = path.join(
      REPO_ROOT,
      "harnesses",
      "pi",
      "pi-extensions",
      "enforcement",
      "src",
      "hooks",
      "phoenix-dev-gate.ts",
    );
    const src = fs.readFileSync(srcPath, "utf8");
    // gate-result.json / cycle-state.json writes are unrelated JSON artifacts,
    // not the step log — only flag writes targeting activeLog/verdictSection.
    assert.ok(
      !/fs\.appendFileSync\(activeLog/.test(src),
      "raw fs.appendFileSync(activeLog, ...) must not remain — route through codegen-log verdict",
    );
    assert.ok(
      !/fs\.writeFileSync\(activeLog/.test(src),
      "raw fs.writeFileSync(activeLog, ...) must not remain — route through codegen-log verdict",
    );
  });

  it("emits '## dev-gate Section' (not the stale '## phoenix-dev-gate Section') via codegen-log verdict", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pdg-solewriter-"));
    try {
      const loggingDir = path.join(tmpDir, "codegen", "logging");
      fs.mkdirSync(loggingDir, { recursive: true });
      const logPath = path.join(loggingDir, "20260101_000000_step1_cycle.jsonl");
      fs.writeFileSync(
        logPath,
        JSON.stringify({
          ev: "role",
          role: "planner-phoenix",
          body: "# Step\n\n## Plan\n\n**Gate**: `true`\n",
        }) + "\n",
      );

      // Fake codegenDir carrying a REAL copy of codegen-log (the actual
      // sole-writer CLI, not a hand-rolled stub) plus fake wiring/render
      // checkers so the test stays hermetic and fast (no real port/browser
      // dependency). This proves genuine codegen-log verdict byte-shape
      // parity while keeping the wiring/render legs stubbed like the other
      // tests in this file.
      assert.ok(
        fs.existsSync(REAL_CODEGEN_LOG_BIN),
        `expected real codegen-log binary at ${REAL_CODEGEN_LOG_BIN}`,
      );
      const fakeCodegenDir = fs.mkdtempSync(
        path.join(os.tmpdir(), "pdg-solewriter-codegendir-"),
      );
      fs.copyFileSync(
        REAL_CODEGEN_LOG_BIN,
        path.join(fakeCodegenDir, "codegen-log"),
      );
      fs.chmodSync(path.join(fakeCodegenDir, "codegen-log"), 0o755);
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
        `process.stdout.write("WIRING_VERDICT=PASS\\n");\n`,
      );
      fs.writeFileSync(
        path.join(hooksLibDir, "render-check.js"),
        `process.stdout.write("RENDER_VERDICT=PASS\\n");\n`,
      );

      process.env["AGENT_TYPE"] = "developer-phoenix-backend";
      process.env["CWD"] = tmpDir;
      process.env["CODEGEN_DIR"] = fakeCodegenDir;

      try {
        const { register } = await import("../phoenix-dev-gate");
        let capturedHandler: (event: unknown) => Promise<unknown>;
        const mockPi = {
          on: (
            _event: string,
            handler: (event: unknown) => Promise<unknown>,
          ) => {
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
        // codegen-log verdict appends one {"ev":"gate","role":"dev-gate",...}
        // JSONL line — never a markdown "## dev-gate Section" header (that
        // shape belonged to the pre-JSONL markdown session log).
        const gateLine = logContents
          .split("\n")
          .filter(Boolean)
          .map((line) => {
            try {
              return JSON.parse(line) as {
                ev?: string;
                role?: string;
                gate?: string;
                result?: string;
              };
            } catch {
              return null;
            }
          })
          .find((obj) => obj?.ev === "gate" && obj?.role === "dev-gate");
        assert.ok(
          gateLine,
          `expected a {"ev":"gate","role":"dev-gate",...} JSONL line, got: ${logContents}`,
        );
        assert.ok(
          !logContents.includes("## dev-gate Section") &&
            !logContents.includes("## phoenix-dev-gate Section"),
          `stale markdown section headers must not appear, got: ${logContents}`,
        );
        assert.equal(
          gateLine!.gate,
          "true",
          `expected gate='true', got: ${JSON.stringify(gateLine)}`,
        );
        assert.ok(
          gateLine!.result?.includes("ALL CLEAR"),
          `expected ALL CLEAR in result, got: ${JSON.stringify(gateLine)}`,
        );
      } finally {
        fs.rmSync(fakeCodegenDir, { recursive: true, force: true });
      }
    } finally {
      delete process.env["AGENT_TYPE"];
      delete process.env["CWD"];
      delete process.env["CODEGEN_DIR"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});

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

const REPO_ROOT = path.resolve(__dirname, "../../../../../../..");
const REAL_CODEGEN_LOG_BIN = path.join(REPO_ROOT, "codegen-log");

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
      // Set up a step log with a Gate directive (planner role JSONL event).
      const loggingDir = path.join(tmpDir, "codegen", "logging");
      fs.mkdirSync(loggingDir, { recursive: true });
      const logPath = path.join(loggingDir, "20260101_000000_step1_cycle.jsonl");
      fs.writeFileSync(
        logPath,
        JSON.stringify({
          ev: "role",
          role: "planner-phoenix",
          body: `# Step\n\n## Plan\n\n**Gate**: \`${gatePasses ? "true" : "false"}\`\n`,
        }) + "\n",
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
      const logPath = path.join(loggingDir, "20260101_000000_step1_cycle.jsonl");
      fs.writeFileSync(
        logPath,
        JSON.stringify({
          ev: "role",
          role: "planner-phoenix",
          body: "# Step\n\n## Plan\n\n**Gate**: `true`\n",
        }) + "\n",
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
      const logPath = path.join(loggingDir, "20260101_000000_step1_cycle.jsonl");
      fs.writeFileSync(
        logPath,
        JSON.stringify({
          ev: "role",
          role: "planner-phoenix",
          body: "# Step\n\n## Plan\n\n**Gate**: `true`\n",
        }) + "\n",
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

// ── Long-gate verdict tests ──────────────────────────────────────────────────
// Verifies that pi phoenix-dev-gate writes a defined INCONCLUSIVE gate-result.json
// for long gates (mode=long) instead of early-returning with nothing written.
// This breaks the commit-guard deadlock on pi-routed Phoenix builds.

describe("phoenix-dev-gate long-gate verdict", () => {
  async function runHookWithGateJsonBlock(
    gateJsonBlock: string,
    tmpDir: string,
  ) {
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    const logPath = path.join(loggingDir, "20260101_000000_step1_cycle.jsonl");
    fs.writeFileSync(
      logPath,
      JSON.stringify({
        ev: "role",
        role: "planner-phoenix",
        body: `# Step\n\n## Plan\n\n\`\`\`gate-json\n${gateJsonBlock}\n\`\`\`\n`,
      }) + "\n",
    );
    return logPath;
  }

  it("long gate writes inconclusive gate-result.json with long-gate-unsupported-on-pi classification", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pdg-long-"));
    try {
      const logPath = await runHookWithGateJsonBlock(
        JSON.stringify({ command: "make ci", mode: "long", timeout: 900 }),
        tmpDir,
      );

      process.env["AGENT_TYPE"] = "developer-phoenix-backend";
      process.env["CWD"] = tmpDir;
      delete process.env["CODEGEN_DIR"];

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

      const gateResultPath = path.join(
        tmpDir,
        "codegen",
        "gate-pending",
        "gate-result.json",
      );
      assert.ok(
        fs.existsSync(gateResultPath),
        `gate-result.json must exist at ${gateResultPath}`,
      );
      const gateResult = JSON.parse(
        fs.readFileSync(gateResultPath, "utf8"),
      ) as {
        verdict: string;
        classification: string;
        mode: string;
      };
      assert.strictEqual(
        gateResult.verdict,
        "inconclusive",
        `expected verdict=inconclusive, got ${gateResult.verdict}`,
      );
      assert.strictEqual(
        gateResult.classification,
        "long-gate-unsupported-on-pi",
        `expected classification=long-gate-unsupported-on-pi, got ${gateResult.classification}`,
      );
      assert.strictEqual(
        gateResult.mode,
        "long",
        `expected mode=long, got ${gateResult.mode}`,
      );

      const logContents = fs.readFileSync(logPath, "utf8");
      assert.ok(
        logContents.includes("INCONCLUSIVE"),
        `expected INCONCLUSIVE in step log, got: ${logContents}`,
      );
      assert.ok(
        !logContents.includes("ALL CLEAR"),
        `expected no ALL CLEAR in step log for long gate, got: ${logContents}`,
      );
    } finally {
      delete process.env["AGENT_TYPE"];
      delete process.env["CWD"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("long gate does NOT run the gate command", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pdg-long-norun-"));
    const markerFile = path.join(tmpDir, "pdg-ran-marker");
    try {
      await runHookWithGateJsonBlock(
        JSON.stringify({
          command: `touch ${markerFile}`,
          mode: "long",
          timeout: 900,
        }),
        tmpDir,
      );

      process.env["AGENT_TYPE"] = "developer-phoenix-backend";
      process.env["CWD"] = tmpDir;
      delete process.env["CODEGEN_DIR"];

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

      assert.ok(
        !fs.existsSync(markerFile),
        `gate command must NOT have run for long gate (marker file found: ${markerFile})`,
      );
    } finally {
      delete process.env["AGENT_TYPE"];
      delete process.env["CWD"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("short gate still writes clear gate-result.json", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pdg-short-reg-"));
    try {
      // Set up fake wiring-check.js and render-check.js (PASS) so the full
      // path executes without erroring on missing scripts.
      const hooksLibDir = path.join(
        tmpDir,
        "harnesses",
        "claude",
        "hooks",
        "lib",
      );
      fs.mkdirSync(hooksLibDir, { recursive: true });
      fs.writeFileSync(
        path.join(hooksLibDir, "wiring-check.js"),
        `process.stdout.write("WIRING_VERDICT=PASS\\n");\n`,
      );
      fs.writeFileSync(
        path.join(hooksLibDir, "render-check.js"),
        `process.stdout.write("RENDER_VERDICT=PASS\\n");\n`,
      );

      const logPath = await runHookWithGateJsonBlock(
        // mode absent → short gate; command `true` always exits 0
        JSON.stringify({ command: "true", mode: "short" }),
        tmpDir,
      );

      process.env["AGENT_TYPE"] = "developer-phoenix-backend";
      process.env["CWD"] = tmpDir;
      process.env["CODEGEN_DIR"] = tmpDir;

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

      const gateResultPath = path.join(
        tmpDir,
        "codegen",
        "gate-pending",
        "gate-result.json",
      );
      assert.ok(
        fs.existsSync(gateResultPath),
        `gate-result.json must exist for short gate at ${gateResultPath}`,
      );
      const gateResult = JSON.parse(
        fs.readFileSync(gateResultPath, "utf8"),
      ) as {
        verdict: string;
        mode: string;
      };
      assert.strictEqual(
        gateResult.verdict,
        "clear",
        `expected verdict=clear for short gate, got ${gateResult.verdict}`,
      );
      assert.strictEqual(
        gateResult.mode,
        "short",
        `expected mode=short, got ${gateResult.mode}`,
      );

      const logContents = fs.readFileSync(logPath, "utf8");
      assert.ok(
        logContents.includes("ALL CLEAR"),
        `expected ALL CLEAR in step log for short gate, got: ${logContents}`,
      );
    } finally {
      delete process.env["AGENT_TYPE"];
      delete process.env["CWD"];
      delete process.env["CODEGEN_DIR"];
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
