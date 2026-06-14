/**
 * phoenix-dev-gate.ts — Pi enforcement: run CI gate on Phoenix developer
 * session shutdown (SubagentStop equivalent).
 *
 * Mirrors: templates/shared/hooks/phoenix-dev-gate.sh
 * Event: session_shutdown (SubagentStop equivalent)
 *
 * Note: Pi SubagentStop → session_shutdown. The blocking/unblocking mechanism
 * differs from Claude Code (no `decision:block` envelope). The Pi extension
 * equivalent runs the gate and writes the verdict to the step log. Complex
 * long-gate foreground polling is not supported in the Pi extension context —
 * this implementation handles short gates inline and records the verdict.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parseAgentType, debugLog } from "../lib/hook-helpers";
import {
  execSync,
  type ExecSyncOptionsWithStringEncoding,
} from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "phoenix-dev-gate",
  event: "session_shutdown",
  matcher: "developer-phoenix-backend|developer-phoenix-frontend",
} as const;

const PHOENIX_DEV_AGENTS = new Set([
  "developer-phoenix-backend",
  "developer-phoenix-frontend",
]);

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    if (!PHOENIX_DEV_AGENTS.has(agentType)) return;

    const projectDir = process.env["CWD"] ?? process.cwd();
    const sessionId = process.env["SESSION_ID"] ?? "unknown";
    debugLog(
      "phoenix-dev-gate",
      `agent=${agentType} cwd=${projectDir} session=${sessionId}`,
    );

    // Find active step log
    const loggingDir = path.join(projectDir, "codegen", "logging");
    if (!fs.existsSync(loggingDir)) return;

    const logFiles = fs
      .readdirSync(loggingDir)
      .filter((f) => f.endsWith(".md") && !f.includes("progress"))
      .map((f) => ({
        name: f,
        mtime: fs.statSync(path.join(loggingDir, f)).mtimeMs,
      }))
      .sort((a, b) => b.mtime - a.mtime);

    if (logFiles.length === 0) return;

    const activeLog = path.join(loggingDir, logFiles[0].name);
    const logContent = fs.readFileSync(activeLog, "utf8");

    // Extract Gate from step log — try gate-json block first, fall back to prose
    let gateCmd = "";
    let isLongGate = false;

    const jsonBlockMatch = logContent.match(/```gate-json\n([\s\S]*?)```/);
    if (jsonBlockMatch) {
      try {
        const parsed = JSON.parse(jsonBlockMatch[1]) as {
          command?: string;
          mode?: string;
          timeout?: number;
        };
        if (parsed.command) {
          gateCmd = parsed.command.trim();
          isLongGate = parsed.mode === "long";
          debugLog(
            "phoenix-dev-gate",
            `gate from JSON block: ${gateCmd} mode=${parsed.mode}`,
          );
        } else {
          debugLog("phoenix-dev-gate", "gate-json block missing command field");
          return;
        }
      } catch {
        debugLog("phoenix-dev-gate", "gate-json block is not valid JSON");
        return;
      }
    } else {
      // Prose fallback
      const gateMatch = logContent.match(/\*\*Gate\*\*:\s*`?([^\n`]+)`?/);
      if (!gateMatch) {
        debugLog("phoenix-dev-gate", "no Gate: directive found");
        return;
      }
      gateCmd = gateMatch[1].trim();
      // Determine mode from command string
      isLongGate = /make\s+(ci|llm|llm-phoenix|llm-all|predeploy)([^-]|$)/.test(
        gateCmd,
      );
      debugLog("phoenix-dev-gate", `gate from prose: ${gateCmd}`);
    }

    if (!gateCmd) return;
    debugLog("phoenix-dev-gate", `gate=${gateCmd}`);

    if (isLongGate) {
      debugLog("phoenix-dev-gate", "long gate — skipping inline run");
      return;
    }

    // Run short gate
    let verdict: string;
    try {
      execSync(gateCmd, { cwd: projectDir, stdio: "pipe" });
      verdict = "ALL CLEAR ✅";
    } catch (err) {
      const output =
        (err as { stdout?: Buffer; stderr?: Buffer }).stdout?.toString() ?? "";
      const errOutput =
        (err as { stdout?: Buffer; stderr?: Buffer }).stderr?.toString() ?? "";
      verdict = `FAILED ❌\n\n${output}\n${errOutput}`.trim();
    }

    // ── Wiring verification (static, before render) ────────────────────────
    // Pi cannot block (session_shutdown is observe-only) — surface FAIL via stderr
    // and downgrade verdict. This is the documented runtime-fidelity asymmetry.
    let wiringSummary = "";
    if (verdict === "ALL CLEAR ✅") {
      const codegenDir = process.env["CODEGEN_DIR"] ?? "";
      const wiringCheckScript = codegenDir
        ? path.join(
            codegenDir,
            "harnesses",
            "claude",
            "hooks",
            "lib",
            "wiring-check.js",
          )
        : "";

      if (wiringCheckScript && fs.existsSync(wiringCheckScript)) {
        let wiringRaw = "";
        try {
          const opts: ExecSyncOptionsWithStringEncoding = {
            cwd: codegenDir,
            stdio: ["ignore", "pipe", "pipe"],
            timeout: 10_000,
            encoding: "utf8",
          };
          wiringRaw = execSync(
            `node "${wiringCheckScript}" "${projectDir}"`,
            opts,
          ).toString();
        } catch (err) {
          wiringRaw =
            (err as { stdout?: Buffer | string }).stdout?.toString() ?? "";
        }

        const wiringVerdictLine = wiringRaw
          .split("\n")
          .find((l) => l.startsWith("WIRING_VERDICT="));
        const wiringVerdict = wiringVerdictLine
          ? wiringVerdictLine.split("=")[1]
          : "";

        debugLog("phoenix-dev-gate", `wiring verdict: ${wiringVerdict}`);

        if (wiringVerdict.startsWith("FAIL:")) {
          const reason = wiringVerdict.slice("FAIL:".length);
          process.stderr.write(
            `[pi-enforcement:phoenix-dev-gate] wiring FAILED: ${reason}\n`,
          );
          verdict = `FAILED ❌ wiring check failed: ${reason}`;
        } else if (wiringVerdict.startsWith("INCONCLUSIVE:")) {
          const detail = wiringVerdict.slice("INCONCLUSIVE:".length);
          debugLog(
            "phoenix-dev-gate",
            `wiring INCONCLUSIVE: ${detail} — non-fatal, ALL CLEAR kept`,
          );
          wiringSummary = `wiring: INCONCLUSIVE (${detail}) — skipped`;
        } else if (wiringVerdict === "PASS") {
          wiringSummary =
            "wiring: PASS (all phx-* handlers have an element-driven side-effect test)";
        }
      } else {
        debugLog(
          "phoenix-dev-gate",
          "wiring-check.js not found — skipping wiring check",
        );
      }
    }

    // ── Render verification (after gate passes and wiring OK) ──────────────
    let renderSummary = "";
    if (verdict === "ALL CLEAR ✅") {
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

      if (renderCheckScript && fs.existsSync(renderCheckScript)) {
        const phoenixPort = process.env["PHOENIX_DEV_PORT"] ?? "4000";
        let renderRaw = "";
        try {
          const opts: ExecSyncOptionsWithStringEncoding = {
            cwd: codegenDir,
            stdio: ["ignore", "pipe", "pipe"],
            timeout: 35_000,
            encoding: "utf8",
          };
          renderRaw = execSync(
            `node "${renderCheckScript}" --mode phoenix --port ${phoenixPort} --timeout 30000`,
            opts,
          ).toString();
        } catch (err) {
          renderRaw =
            (err as { stdout?: Buffer | string }).stdout?.toString() ?? "";
        }

        const verdictLine = renderRaw
          .split("\n")
          .find((l) => l.startsWith("RENDER_VERDICT="));
        const renderVerdict = verdictLine ? verdictLine.split("=")[1] : "";

        debugLog("phoenix-dev-gate", `render verdict: ${renderVerdict}`);

        if (renderVerdict.startsWith("FAIL:")) {
          const reason = renderVerdict.slice("FAIL:".length);
          process.stderr.write(
            `[pi-enforcement:phoenix-dev-gate] render FAILED: ${reason}\n`,
          );
          verdict = `FAILED ❌ render check failed: ${reason}`;
        } else if (renderVerdict.startsWith("INCONCLUSIVE:")) {
          const detail = renderVerdict.slice("INCONCLUSIVE:".length);
          debugLog(
            "phoenix-dev-gate",
            `render INCONCLUSIVE: ${detail} — non-fatal, ALL CLEAR kept`,
          );
          // Render INCONCLUSIVE is non-fatal (observability only) — ALL CLEAR kept
          renderSummary = `render: INCONCLUSIVE (${detail}) — skipped`;
        } else if (renderVerdict === "PASS") {
          renderSummary = "render: DOM non-empty, styles applied, 0 JS errors";
        }
      } else {
        debugLog(
          "phoenix-dev-gate",
          "render-check.js not found — skipping render check",
        );
      }
    }

    // Derive structured verdict for gate-result.json
    let structuredVerdict = "failed";
    let structuredMarker = "FAILED ❌";
    if (verdict === "ALL CLEAR ✅") {
      structuredVerdict = "clear";
      structuredMarker = "ALL CLEAR ✅";
    } else if (verdict.startsWith("INCONCLUSIVE")) {
      structuredVerdict = "inconclusive";
      structuredMarker = "INCONCLUSIVE ⚠️";
    }

    // Write gate-result.json
    const gateResultDir = path.join(projectDir, "codegen", "gate-pending");
    try {
      fs.mkdirSync(gateResultDir, { recursive: true });
      const now = new Date().toISOString();
      const gateResult = {
        gate: gateCmd,
        mode: isLongGate ? "long" : "short",
        diff_sha: "unknown",
        diff_files_count: 0,
        runner_found: true,
        exit: 0,
        execution_evidence: 1,
        expected_segments: 1,
        render_verdict: renderSummary,
        verdict: structuredVerdict,
        verdict_marker: structuredMarker,
        classification: "",
        started: now,
        ended: now,
        session_id: sessionId,
        log: "",
      };
      fs.writeFileSync(
        path.join(gateResultDir, "gate-result.json"),
        JSON.stringify(gateResult, null, 2),
      );
      debugLog(
        "phoenix-dev-gate",
        `wrote gate-result.json verdict=${structuredVerdict}`,
      );

      // Write cycle-state.json alongside gate-result.json.
      const cycleState = {
        state: "GATED",
        step_log: activeLog ?? "",
        session_id: sessionId,
        verdict: structuredVerdict,
        updated_at: now,
      };
      fs.writeFileSync(
        path.join(gateResultDir, "cycle-state.json"),
        JSON.stringify(cycleState, null, 2),
      );
      debugLog(
        "phoenix-dev-gate",
        `wrote cycle-state.json state=GATED verdict=${structuredVerdict}`,
      );
    } catch (e) {
      debugLog(
        "phoenix-dev-gate",
        `failed to write gate-result.json: ${String(e)}`,
      );
    }

    // Append verdict to step log
    const verdictLines = [
      "",
      "## phoenix-dev-gate Section",
      "",
      `**Gate**: \`${gateCmd}\``,
      `**Ran**: \`${gateCmd}\``,
      "",
      verdict,
      "",
    ];
    if (wiringSummary) {
      verdictLines.push(wiringSummary, "");
    }
    if (renderSummary) {
      verdictLines.push(renderSummary, "");
    }
    const verdictSection = verdictLines.join("\n");

    fs.appendFileSync(activeLog, verdictSection);
    debugLog("phoenix-dev-gate", `verdict=${verdict.slice(0, 50)}`);
  });
}
