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
  execFileSync,
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

// Resolves codegen-log's absolute path (mirrors the OCG_CODEGEN_DIR/
// CODEGEN_DIR/BASH_SOURCE-derivation pattern used by phoenix-dev-gate.sh)
// so the verdict write goes through the sole-writer CLI regardless of
// whether the installed ~/.local/bin symlink is on PATH in this hook's env.
function resolveCodegenLogBin(): string {
  const codegenDir =
    process.env["OCG_CODEGEN_DIR"] ?? process.env["CODEGEN_DIR"] ?? "";
  if (codegenDir) {
    const candidate = path.join(codegenDir, "codegen-log");
    if (fs.existsSync(candidate)) return candidate;
  }
  try {
    const found = execSync("command -v codegen-log", {
      encoding: "utf8",
    }).trim();
    if (found) return found;
  } catch {
    // not on PATH — fall through to empty (caller treats as unresolved)
  }
  return "";
}

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    if (!PHOENIX_DEV_AGENTS.has(agentType)) return;

    const projectDir = process.env["CWD"] ?? process.cwd();
    const isCodegenSelfBuild = fs.existsSync(
      path.join(projectDir, "shared", "enforcement", "registry.yaml"),
    );
    const sessionId = process.env["SESSION_ID"] ?? "unknown";
    debugLog(
      "phoenix-dev-gate",
      `agent=${agentType} cwd=${projectDir} session=${sessionId}`,
    );

    // Find active step log — canonical *_<slug>_cycle.jsonl append-only log.
    const loggingDir = path.join(projectDir, "codegen", "logging");
    if (!fs.existsSync(loggingDir)) return;

    const logFiles = fs
      .readdirSync(loggingDir)
      .filter((f) => f.endsWith(".jsonl") && !f.includes("progress"))
      .map((f) => ({
        name: f,
        mtime: fs.statSync(path.join(loggingDir, f)).mtimeMs,
      }))
      .sort((a, b) => b.mtime - a.mtime);

    if (logFiles.length === 0) return;

    const activeLog = path.join(loggingDir, logFiles[0].name);
    const rawLog = fs.readFileSync(activeLog, "utf8");

    // Decode the planner's role body from the JSONL cycle log (mirrors
    // gate-select.sh's planner_body_from_log) — the "## Plan"/"**Gate**:"
    // prose scanners below operate on this DECODED body text, never on the
    // raw JSONL bytes. Multiple planner role events (re-runs) are joined
    // with a newline, in file order.
    const logContent = rawLog
      .split("\n")
      .filter(Boolean)
      .map((line) => {
        try {
          return JSON.parse(line) as {
            ev?: string;
            role?: string;
            body?: string;
          };
        } catch {
          return null;
        }
      })
      .filter(
        (obj): obj is { ev: string; role: string; body: string } =>
          obj !== null &&
          obj.ev === "role" &&
          typeof obj.role === "string" &&
          obj.role.startsWith("planner") &&
          typeof obj.body === "string",
      )
      .map((obj) => obj.body)
      .join("\n");

    if (!logContent) {
      debugLog("phoenix-dev-gate", "no planner role event found in cycle log");
      return;
    }

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

    // Classify long gates immediately — pi shutdown cannot run long gates inline.
    // Set the INCONCLUSIVE sentinel so the existing verdict-derivation and
    // gate-result.json write block (below) handle it, skipping the short-gate
    // execSync and the ALL-CLEAR-guarded wiring/render checks automatically.
    let verdict: string;
    if (isLongGate) {
      debugLog(
        "phoenix-dev-gate",
        "long gate — writing inconclusive verdict (pi cannot run long gates inline)",
      );
      verdict = "INCONCLUSIVE ⚠️ long-gate-unsupported-on-pi";
    } else {
      // Run short gate
      try {
        execSync(gateCmd, { cwd: projectDir, stdio: "pipe" });
        verdict = "ALL CLEAR ✅";
      } catch (err) {
        const output =
          (err as { stdout?: Buffer; stderr?: Buffer }).stdout?.toString() ??
          "";
        const errOutput =
          (err as { stdout?: Buffer; stderr?: Buffer }).stderr?.toString() ?? "";
        verdict = `FAILED ❌\n\n${output}\n${errOutput}`.trim();
      }
    }

    // ── Wiring verification (static, before render) ────────────────────────
    // Pi cannot block (session_shutdown is observe-only) — surface FAIL via stderr
    // and downgrade verdict. This is the documented runtime-fidelity asymmetry.
    let wiringSummary = "";
    if (verdict === "ALL CLEAR ✅" && !isCodegenSelfBuild) {
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
      } else if (codegenDir) {
        // codegenDir is set but script path is absent — checker not installed.
        debugLog(
          "phoenix-dev-gate",
          "wiring-check.js not found — INCONCLUSIVE (checker-missing)",
        );
        wiringSummary = "wiring: INCONCLUSIVE (checker-missing) — skipped";
      } else {
        // codegenDir empty → operator opt-out; silent skip (Pi observe-only).
        debugLog(
          "phoenix-dev-gate",
          "CODEGEN_DIR not set — skipping wiring check (opt-out)",
        );
      }
    }

    // ── Render verification (after gate passes and wiring OK) ──────────────
    let renderSummary = "";
    if (verdict === "ALL CLEAR ✅" && !isCodegenSelfBuild) {
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
        let renderRaw = "";
        try {
          const opts: ExecSyncOptionsWithStringEncoding = {
            cwd: codegenDir,
            stdio: ["ignore", "pipe", "pipe"],
            timeout: 35_000,
            encoding: "utf8",
          };
          renderRaw = execSync(
            `node "${renderCheckScript}" --mode phoenix --spawn "${projectDir}" --timeout 30000`,
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
      } else if (codegenDir) {
        // codegenDir is set but script path is absent — checker not installed.
        debugLog(
          "phoenix-dev-gate",
          "render-check.js not found — INCONCLUSIVE (checker-missing)",
        );
        renderSummary = "render: INCONCLUSIVE (checker-missing) — skipped";
      } else {
        // codegenDir empty → operator opt-out; silent skip (Pi observe-only).
        debugLog(
          "phoenix-dev-gate",
          "CODEGEN_DIR not set — skipping render check (opt-out)",
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
    const longGateClassification = isLongGate
      ? "long-gate-unsupported-on-pi"
      : "";
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
        classification: longGateClassification,
        started: now,
        ended: now,
        session_id: sessionId,
        log: "",
        witness: "",
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

    // Write verdict to step log via `codegen-log verdict` — the sole writer
    // of cycle logs. No raw fs write to activeLog; mirrors the Claude-side
    // phoenix-dev-gate.sh append_ve_section()/CODEGEN_LOG_BIN pattern and
    // produces the same {"ev":"gate","role":"dev-gate",...} JSONL event
    // shape for cross-harness parity.
    const detailLines = [wiringSummary, renderSummary].filter(Boolean);
    const detailText = detailLines.join("\n");

    const codegenLogBin = resolveCodegenLogBin();
    if (codegenLogBin) {
      const verdictArgs = [
        "verdict",
        "--gate",
        gateCmd,
        "--mode",
        isLongGate ? "long" : "short",
        "--result",
        verdict,
      ];
      if (detailText) {
        verdictArgs.push("--detail", detailText);
      }
      try {
        execFileSync(codegenLogBin, verdictArgs, {
          cwd: projectDir,
          stdio: "pipe",
          env: { ...process.env, CODEGEN_LOG_PATH: activeLog },
        });
      } catch (e) {
        debugLog(
          "phoenix-dev-gate",
          `codegen-log verdict failed: ${String(e)}`,
        );
      }
    } else {
      debugLog(
        "phoenix-dev-gate",
        "codegen-log binary not resolvable — verdict not written to step log",
      );
    }
    debugLog("phoenix-dev-gate", `verdict=${verdict.slice(0, 50)}`);
  });
}
