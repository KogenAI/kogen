/**
 * Tests for step-log-completeness hook.
 * Mirrors cases from step-log-completeness_test.sh.
 * Note: Pi session_shutdown event — cannot block. Hook warns via stderr only.
 */

import { describe, it, before, after, afterEach } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

describe("step-log-completeness", () => {
  let _capturedHandler: (event: unknown) => Promise<unknown>;

  const mockPi = {
    on: (_event: string, handler: (event: unknown) => Promise<unknown>) => {
      _capturedHandler = handler;
    },
  };

  afterEach(() => {
    delete process.env["PI_ROLE"];
    delete process.env["CWD"];
  });

  async function runHook(stop_hook_active = false, cwd = "/tmp") {
    // The hook reads process.env["CWD"], not the event payload's cwd field —
    // set it explicitly so tests actually exercise the intended tmpDir scan.
    process.env["CWD"] = cwd;
    const { register } = await import("../step-log-completeness");
    register(
      mockPi as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI,
    );
    return _capturedHandler({
      toolName: "session_shutdown",
      toolCallId: "test-id",
      input: { cwd, stop_hook_active },
    });
  }

  it("stop_hook_active=true short-circuits without crash", async () => {
    const result = await runHook(true);
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("no log found exits cleanly (no block)", async () => {
    const result = await runHook(false, "/tmp/no-such-dir-for-step-log-test");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("normal shutdown does not crash", async () => {
    const result = await runHook(false, "/tmp");
    assert.ok(result == null || (result as { block?: boolean }).block !== true);
  });

  it("does not warn when PI_ROLE=shape (investigative mode — build-runtime gate skipped)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "step-log-completeness-role-test-"));
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    const logFile = path.join(loggingDir, "20260101_120000_step1_test.md");
    fs.writeFileSync(
      logFile,
      "## developer-phoenix-backend Section\n\nSome content\n\n## dev-gate Section\n\nALL CLEAR ✅\n",
      "utf8",
    );
    const now = Date.now();
    fs.utimesSync(logFile, new Date(now), new Date(now));

    process.env["PI_ROLE"] = "shape";

    let stderrOutput = "";
    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (s: string) => {
      stderrOutput += s;
      return true;
    };
    try {
      await runHook(false, tmpDir);
    } finally {
      process.stderr.write = origWrite;
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }

    assert.ok(
      !stderrOutput.includes("WARNING"),
      "expected no WARNING when PI_ROLE=shape (investigative mode)",
    );
  });

  it("still warns when PI_ROLE=build (explicit build role enforces)", async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "step-log-completeness-role-test-"));
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    const logFile = path.join(loggingDir, "20260101_120000_step1_test.md");
    fs.writeFileSync(
      logFile,
      "## developer-phoenix-backend Section\n\nSome content\n\n## dev-gate Section\n\nALL CLEAR ✅\n",
      "utf8",
    );
    const now = Date.now();
    fs.utimesSync(logFile, new Date(now), new Date(now));

    process.env["PI_ROLE"] = "build";

    let stderrOutput = "";
    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (s: string) => {
      stderrOutput += s;
      return true;
    };
    try {
      await runHook(false, tmpDir);
    } finally {
      process.stderr.write = origWrite;
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }

    assert.ok(
      stderrOutput.includes("WARNING"),
      "expected WARNING when PI_ROLE=build (explicit build role)",
    );
  });

  it("active log path resolves but read throws — INCONCLUSIVE warning, no crash", async () => {
    // A directory named *.md passes readdirSync's endsWith(".md") filter and
    // statSync succeeds on it, but fs.readFileSync throws EISDIR — the
    // present-but-unreadable anomaly path (observe-only: warn, don't crash).
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "step-log-completeness-unreadable-"),
    );
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    const logDirAsFile = path.join(loggingDir, "20260101_120000_step1_test.md");
    fs.mkdirSync(logDirAsFile, { recursive: true });

    let stderrOutput = "";
    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (s: string) => {
      stderrOutput += s;
      return true;
    };
    try {
      const result = await runHook(false, tmpDir);
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
        `expected no throw/no block but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.stderr.write = origWrite;
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }

    assert.ok(
      stderrOutput.includes("INCONCLUSIVE") &&
        stderrOutput.includes("could not be read"),
      `expected INCONCLUSIVE could-not-be-read warning but got: ${stderrOutput}`,
    );
  });

  it("gate-result.json path resolves but read throws — INCONCLUSIVE warning, falls back to log marker", async () => {
    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "step-log-completeness-gate-unreadable-"),
    );
    const loggingDir = path.join(tmpDir, "codegen", "logging");
    fs.mkdirSync(loggingDir, { recursive: true });
    const logFile = path.join(loggingDir, "20260101_120000_step1_test.md");
    fs.writeFileSync(
      logFile,
      "## developer-phoenix-backend Section\n\nSome content\n\nALL CLEAR ✅\n",
      "utf8",
    );
    const now = Date.now();
    fs.utimesSync(logFile, new Date(now), new Date(now));

    // gate-result.json exists (existsSync true) but is a directory —
    // readFileSync throws. Proven-present, not absent.
    const gateResultDirAsFile = path.join(
      tmpDir,
      "codegen",
      "gate-pending",
      "gate-result.json",
    );
    fs.mkdirSync(gateResultDirAsFile, { recursive: true });

    let stderrOutput = "";
    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (s: string) => {
      stderrOutput += s;
      return true;
    };
    try {
      const result = await runHook(false, tmpDir);
      assert.ok(
        result == null || (result as { block?: boolean }).block !== true,
        `expected no throw/no block but got: ${JSON.stringify(result)}`,
      );
    } finally {
      process.stderr.write = origWrite;
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }

    assert.ok(
      stderrOutput.includes("INCONCLUSIVE") &&
        stderrOutput.includes("gate-result.json"),
      `expected INCONCLUSIVE gate-result.json warning but got: ${stderrOutput}`,
    );
  });

  describe("empty-body content-floor (observe-only)", () => {
    let tmpDir: string;

    before(() => {
      tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "step-log-completeness-test-"));
      const loggingDir = path.join(tmpDir, "codegen", "logging");
      fs.mkdirSync(loggingDir, { recursive: true });
      // Write a recent log with developer section header but empty body
      const logFile = path.join(loggingDir, "20260101_120000_step1_test.md");
      fs.writeFileSync(
        logFile,
        "## developer-phoenix-backend Section\n\n",
        "utf8",
      );
      // Touch the file to ensure it's within the 60-min window
      const now = Date.now();
      fs.utimesSync(logFile, new Date(now), new Date(now));
    });

    after(() => {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    });

    it("empty developer section body — no throw, no block (warn-only path)", async () => {
      // REDUCED-FIDELITY: Pi cannot block. Assert only that the handler does not
      // throw and does not return a block decision (warn-only path).
      const result = await runHook(false, tmpDir);
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    });

    it("log with INTERRUPTED marker — no throw, death-marker skip fires", async () => {
      const loggingDir = path.join(tmpDir, "codegen", "logging");
      const logFile = path.join(loggingDir, "20260101_130000_step2_test.md");
      fs.writeFileSync(
        logFile,
        "## developer-phoenix-backend Section\n\n### INTERRUPTED ⚠️ — developer dropped; re-spawning (attempt 1/2)\n",
        "utf8",
      );
      const now = Date.now();
      fs.utimesSync(logFile, new Date(now), new Date(now));

      const result = await runHook(false, tmpDir);
      assert.ok(result == null || (result as { block?: boolean }).block !== true);
    });

    it("retro-first reviewer body then trailing prose — no OBSERVE-ONLY warning", async () => {
      const loggingDir = path.join(tmpDir, "codegen", "logging");
      const logFile = path.join(loggingDir, "20260101_140000_step3_test.md");
      fs.writeFileSync(
        logFile,
        [
          "## reviewer-phoenix Section",
          "",
          "### What I Learned This Step",
          "",
          "- nothing notable",
          "",
          "Verdict: APPROVED — ready for curator.",
          "",
        ].join("\n"),
        "utf8",
      );
      // Explicit future mtime (well past any prior test's mtime in this shared
      // tmpDir) so the disk-scan's most-recently-modified sort deterministically
      // picks THIS file, regardless of Date.now() ms-resolution ties.
      const mtime = new Date(Date.now() + 10_000);
      fs.utimesSync(logFile, mtime, mtime);

      let stderrOutput = "";
      const origWrite = process.stderr.write.bind(process.stderr);
      process.stderr.write = (s: string) => {
        stderrOutput += s;
        return true;
      };
      try {
        await runHook(false, tmpDir);
      } finally {
        process.stderr.write = origWrite;
      }

      assert.ok(
        !stderrOutput.includes("OBSERVE-ONLY"),
        "expected no OBSERVE-ONLY warning for retro-first-then-prose body",
      );
    });

    it("truly-empty reviewer section body — OBSERVE-ONLY warning still fires", async () => {
      const loggingDir = path.join(tmpDir, "codegen", "logging");
      const logFile = path.join(loggingDir, "20260101_150000_step4_test.md");
      fs.writeFileSync(
        logFile,
        ["## reviewer-phoenix Section", "", "### What I Learned This Step", "", "- nothing notable", ""].join(
          "\n",
        ),
        "utf8",
      );
      // Explicit future mtime, later than the sibling test's +10s offset, so
      // this file deterministically wins the most-recently-modified disk scan.
      const mtime = new Date(Date.now() + 20_000);
      fs.utimesSync(logFile, mtime, mtime);

      let stderrOutput = "";
      const origWrite = process.stderr.write.bind(process.stderr);
      process.stderr.write = (s: string) => {
        stderrOutput += s;
        return true;
      };
      try {
        await runHook(false, tmpDir);
      } finally {
        process.stderr.write = origWrite;
      }

      assert.ok(
        stderrOutput.includes("OBSERVE-ONLY"),
        "expected OBSERVE-ONLY warning for truly-empty retro-only body",
      );
    });
  });
});
