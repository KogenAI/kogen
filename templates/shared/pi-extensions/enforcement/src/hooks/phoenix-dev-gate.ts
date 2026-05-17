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
import { execSync } from "node:child_process";
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

    // Extract Gate: directive from step log
    const gateMatch = logContent.match(/\*\*Gate\*\*:\s*`?([^\n`]+)`?/);
    if (!gateMatch) {
      debugLog("phoenix-dev-gate", "no Gate: directive found");
      return;
    }

    const gateCmd = gateMatch[1].trim();
    debugLog("phoenix-dev-gate", `gate=${gateCmd}`);

    // Only run short gates inline (not make ci, make llm-phoenix, etc.)
    const isLongGate =
      /make\s+(ci|llm|llm-phoenix|llm-all|predeploy)([^-]|$)/.test(gateCmd);

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

    // Append verdict to step log
    const verdictSection = [
      "",
      "## phoenix-dev-gate Section",
      "",
      `**Gate**: \`${gateCmd}\``,
      `**Ran**: \`${gateCmd}\``,
      "",
      verdict,
      "",
    ].join("\n");

    fs.appendFileSync(activeLog, verdictSection);
    debugLog("phoenix-dev-gate", `verdict=${verdict.slice(0, 50)}`);
  });
}
