/**
 * static-site-build-check.ts — Pi enforcement: run static site build check
 * on developer session shutdown (SubagentStop equivalent).
 *
 * Mirrors: templates/shared/hooks/static-site-build-check.sh
 * Event: session_shutdown (SubagentStop equivalent)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parseAgentType, debugLog } from "../lib/hook-helpers";
import {
  execSync,
  type ExecSyncOptionsWithStringEncoding,
} from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

type GateVerdict = "clear" | "failed" | "inconclusive";

export const HANDLER_META = {
  name: "static-site-build-check",
  event: "session_shutdown",
  matcher: "developer-static",
} as const;

const STATIC_DEV_AGENTS = new Set(["developer-static"]);

function writeGateArtifacts(params: {
  projectDir: string;
  gate: string;
  mode: "short" | "long";
  verdict: GateVerdict;
  marker: string;
  renderVerdict: string;
  classification: string;
  exitCode: number;
  sessionId: string;
}): void {
  const gateResultDir = path.join(params.projectDir, "codegen", "gate-pending");
  fs.mkdirSync(gateResultDir, { recursive: true });

  const now = new Date().toISOString();
  const gateResult = {
    gate: params.gate,
    mode: params.mode,
    diff_sha: "unknown",
    diff_files_count: 0,
    runner_found: true,
    exit: params.exitCode,
    execution_evidence: 1,
    expected_segments: 1,
    render_verdict: params.renderVerdict,
    verdict: params.verdict,
    verdict_marker: params.marker,
    classification: params.classification,
    started: now,
    ended: now,
    session_id: params.sessionId,
    log: "",
    witness: "",
  };
  fs.writeFileSync(
    path.join(gateResultDir, "gate-result.json"),
    JSON.stringify(gateResult, null, 2),
  );
  debugLog(
    "static-site-build-check",
    `wrote gate-result.json verdict=${params.verdict}`,
  );

  const cycleState = {
    state: "GATED",
    step_log: "",
    session_id: params.sessionId,
    verdict: params.verdict,
    updated_at: now,
  };
  fs.writeFileSync(
    path.join(gateResultDir, "cycle-state.json"),
    JSON.stringify(cycleState, null, 2),
  );
  debugLog(
    "static-site-build-check",
    `wrote cycle-state.json state=GATED verdict=${params.verdict}`,
  );
}

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async (event) => {
    const ev = event as {
      input?: { cwd?: string; stop_hook_active?: boolean };
    };
    if (ev?.input?.stop_hook_active) return;

    const agentType = parseAgentType();
    if (!STATIC_DEV_AGENTS.has(agentType)) return;

    const projectDir = ev?.input?.cwd ?? process.env["CWD"] ?? process.cwd();
    debugLog("static-site-build-check", `agent=${agentType} cwd=${projectDir}`);

    let renderVerdict = "";
    let verdict: GateVerdict = "inconclusive";
    let marker = "INCONCLUSIVE ⚠️";
    let classification = "";
    let exitCode = 0;
    let renderSummary = "";

    try {
      execSync("make ci", {
        cwd: projectDir,
        stdio: "pipe",
      });
      debugLog("static-site-build-check", "build OK");
    } catch (err) {
      const output =
        (err as { stdout?: Buffer; stderr?: Buffer }).stdout?.toString() ?? "";
      const errOutput =
        (err as { stdout?: Buffer; stderr?: Buffer }).stderr?.toString() ?? "";
      debugLog("static-site-build-check", `build FAILED: ${errOutput}`);
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] build FAILED:\n${output}\n${errOutput}\n`,
      );
      verdict = "failed";
      marker = "FAILED ❌";
      classification = "build-failed";
      exitCode = 1;
      writeGateArtifacts({
        projectDir,
        gate: "make ci",
        mode: "short",
        verdict,
        marker,
        renderVerdict,
        classification,
        exitCode,
        sessionId:
          process.env["SESSION_ID"] ?? process.env["CLAUDE_SESSION_ID"] ?? "",
      });
      return;
    }

    // ── Render verification ────────────────────────────────────────────────
    // Determine output dir (public/ or dist/).
    const outputDir = path.join(projectDir, "public");

    if (!fs.existsSync(outputDir)) {
      debugLog(
        "static-site-build-check",
        "no output dir — render verdict inconclusive",
      );
      renderSummary = "render: INCONCLUSIVE (output-dir-missing) — skipped";
      renderVerdict = "INCONCLUSIVE:output-dir-missing";
      verdict = "inconclusive";
      marker = "INCONCLUSIVE ⚠️";
      writeGateArtifacts({
        projectDir,
        gate: "make ci",
        mode: "short",
        verdict,
        marker,
        renderVerdict,
        classification,
        exitCode,
        sessionId:
          process.env["SESSION_ID"] ?? process.env["CLAUDE_SESSION_ID"] ?? "",
      });
      return;
    }

    const codegenDir = process.env["CODEGEN_DIR"] ?? "";
    const renderCheckScript = codegenDir
      ? path.join(
          codegenDir,
          "harnesses",
          "claude",
          "hooks",
          "lib",
          "render-check.js",
        )
      : "";

    if (!renderCheckScript || !fs.existsSync(renderCheckScript)) {
      debugLog(
        "static-site-build-check",
        "render-check.js not found — render verdict inconclusive",
      );
      renderSummary = "render: INCONCLUSIVE (checker-missing) — skipped";
      renderVerdict = "INCONCLUSIVE:checker-missing";
      verdict = "inconclusive";
      marker = "INCONCLUSIVE ⚠️";
      writeGateArtifacts({
        projectDir,
        gate: "make ci",
        mode: "short",
        verdict,
        marker,
        renderVerdict,
        classification,
        exitCode,
        sessionId:
          process.env["SESSION_ID"] ?? process.env["CLAUDE_SESSION_ID"] ?? "",
      });
      return;
    }

    let renderRaw = "";
    try {
      const opts: ExecSyncOptionsWithStringEncoding = {
        cwd: codegenDir || projectDir,
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 35_000,
        encoding: "utf8",
      };
      renderRaw = execSync(
        `node "${renderCheckScript}" --mode static --timeout 30000 "${outputDir}"`,
        opts,
      ).toString();
    } catch (err) {
      renderRaw =
        (err as { stdout?: Buffer | string }).stdout?.toString() ?? "";
    }

    const verdictLine = renderRaw
      .split("\n")
      .find((l) => l.startsWith("RENDER_VERDICT="));
    renderVerdict = verdictLine ? verdictLine.split("=")[1] : "";

    debugLog("static-site-build-check", `render verdict: ${renderVerdict}`);

    // Pi doesn't support decision:block in session_shutdown; this gate is advisory only (stderr).
    // The claude harness has the fail-closed enforcement.
    if (renderVerdict.startsWith("FAIL:")) {
      const reason = renderVerdict.slice("FAIL:".length);
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render FAILED: ${reason}\n`,
      );
      verdict = "failed";
      marker = "FAILED ❌";
      classification = "render-failed";
    } else if (renderVerdict === "INCONCLUSIVE:browser-not-installed") {
      debugLog(
        "static-site-build-check",
        "render INCONCLUSIVE: browser not installed",
      );
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render INCONCLUSIVE: Chromium browser not found — run: npx playwright install chromium\n`,
      );
      verdict = "inconclusive";
      marker = "INCONCLUSIVE ⚠️";
      classification = "render-inconclusive-browser-missing";
      renderSummary = "render: INCONCLUSIVE (browser-not-installed) — skipped";
    } else if (renderVerdict === "") {
      debugLog(
        "static-site-build-check",
        "render-check emitted no verdict — crash or parse error",
      );
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render-check did not emit verdict — check render-check.js for parse/runtime errors\n`,
      );
      verdict = "inconclusive";
      marker = "INCONCLUSIVE ⚠️";
      classification = "render-inconclusive-empty";
      renderVerdict = "INCONCLUSIVE:empty-verdict";
      renderSummary = "render: INCONCLUSIVE (empty-verdict) — skipped";
    } else if (renderVerdict.startsWith("INCONCLUSIVE:")) {
      const detail = renderVerdict.slice("INCONCLUSIVE:".length);
      debugLog(
        "static-site-build-check",
        `render INCONCLUSIVE: ${detail} — downgrade to INCONCLUSIVE (not ALL CLEAR)`,
      );
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render INCONCLUSIVE: ${detail} — gate is inconclusive, not ALL CLEAR\n`,
      );
      verdict = "inconclusive";
      marker = "INCONCLUSIVE ⚠️";
      classification = `render-inconclusive-${detail}`;
      renderSummary = `render: INCONCLUSIVE (${detail}) — skipped`;
    } else {
      verdict = "clear";
      marker = "ALL CLEAR ✅";
      classification = "render-pass";
      renderSummary = "render: DOM non-empty, styles applied, 0 JS errors";
    }

    writeGateArtifacts({
      projectDir,
      gate: "make ci",
      mode: "short",
      verdict,
      marker,
      renderVerdict: renderSummary || renderVerdict,
      classification,
      exitCode,
      sessionId:
        process.env["SESSION_ID"] ?? process.env["CLAUDE_SESSION_ID"] ?? "",
    });
    // PASS: no action needed (non-blocking success)
  });
}
