/**
 * stop-gate-failure-breaker.ts — Pi enforcement: failure-spiral circuit-breaker.
 *
 * Mirrors: harnesses/claude/hooks/stop-gate-failure-breaker.sh
 * Event: session_shutdown (SubagentStop equivalent)
 *
 * Note: Pi session_shutdown is observe-only — it CANNOT block. This hook
 * MEASURES accumulated FAILED ❌ verdicts in the active step log, cross-checks
 * gate-result.json, and at threshold ≥3 SURFACES a planner-escalation message
 * via stderr + a step-log marker (behavioral parity with the claude block).
 * Same 2-surface-per-step cap. Counter: /tmp/pi-gate-breaker-<session>.count
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parseAgentType, debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

export const HANDLER_META = {
  name: "stop-gate-failure-breaker",
  event: "session_shutdown",
  matcher: "developer-phoenix-backend|developer-phoenix-frontend|developer-static",
} as const;

const DEV_AGENTS = new Set([
  "developer-phoenix-backend",
  "developer-phoenix-frontend",
  "developer-static",
]);

const FAILED_THRESHOLD = 3;
const SURFACE_CAP = 2;

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    if (!DEV_AGENTS.has(agentType)) return;

    const projectDir = process.env["CWD"] ?? process.cwd();
    const sessionId = process.env["SESSION_ID"] ?? "unknown";

    // Resolve active step log (mtime-sorted, exclude progress) — mirror the claude .sh twin.
    const loggingDir = path.join(projectDir, "codegen", "logging");
    if (!fs.existsSync(loggingDir)) return;
    const logFiles = fs
      .readdirSync(loggingDir)
      .filter((f) => f.endsWith(".jsonl") && !f.includes("progress"))
      .map((f) => ({ name: f, mtime: fs.statSync(path.join(loggingDir, f)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime);
    if (logFiles.length === 0) return;
    const activeLog = path.join(loggingDir, logFiles[0].name);

    // Per-step surface cap (line1=step scope, line2=count) — mirror claude .sh:64-81.
    const counterFile = path.join(os.tmpdir(), `pi-gate-breaker-${sessionId}.count`);
    let prevStep = "";
    let surfaceCount = 0;
    try {
      const raw = fs.readFileSync(counterFile, "utf8").split("\n");
      prevStep = raw[0] ?? "";
      surfaceCount = parseInt((raw[1] ?? "").trim(), 10) || 0;
    } catch {
      surfaceCount = 0;
    }
    if (activeLog !== prevStep) surfaceCount = 0; // forward progress resets budget
    if (surfaceCount >= SURFACE_CAP) {
      fs.rmSync(counterFile, { force: true });
      debugLog("stop-gate-failure-breaker", `cap=${surfaceCount} reached — releasing`);
      return;
    }

    // Count FAILED ❌ in the active step log.
    const logContent = fs.readFileSync(activeLog, "utf8");
    const failedCount = (logContent.match(/FAILED ❌/g) ?? []).length;

    // Cross-check latest gate verdict from gate-result.json (written by the Elixir loop's LoopGate).
    let verdict = "";
    try {
      const gr = JSON.parse(
        fs.readFileSync(path.join(projectDir, "codegen", "gate-pending", "gate-result.json"), "utf8"),
      ) as { verdict?: string };
      verdict = gr.verdict ?? "";
    } catch {
      verdict = "";
    }

    debugLog("stop-gate-failure-breaker", `failed=${failedCount} verdict=${verdict} surfaces=${surfaceCount}`);

    if (failedCount < FAILED_THRESHOLD || verdict !== "failed") return;

    // Threshold crossed — SURFACE escalation (pi cannot block).
    surfaceCount += 1;
    fs.writeFileSync(counterFile, `${activeLog}\n${surfaceCount}\n`);
    const msg =
      `BLOCKED by stop-gate-failure-breaker: dev-gate has failed ${failedCount} times with no progress. ` +
      `Do NOT re-spawn the developer. Escalate to planner-phoenix with the failure context and gate log. ` +
      `(gate-breaker surface ${surfaceCount}/${SURFACE_CAP})`;
    process.stderr.write(`[pi-enforcement:stop-gate-failure-breaker] ${msg}\n`);
    fs.appendFileSync(activeLog, `\n## stop-gate-failure-breaker Section\n\n${msg}\n`);
  });
}
