/**
 * subagent-retrospective-guard.ts — Pi enforcement: warn when a subagent stops
 * without a ### What I Learned This Step block in its step log section.
 *
 * Mirrors: harnesses/claude/hooks/subagent-retrospective-guard.sh
 * Event: session_shutdown (SubagentStop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * Gate (agent type): only enforces for:
 *   developer-phoenix-backend, developer-phoenix-frontend,
 *   reviewer-phoenix, reviewer-static,
 *   planner-phoenix, planner-static
 *
 * Logic:
 *   Disk-scan for active step log → find ## <role> Section (or ## Plan for
 *   planner-phoenix) → extract section body → check for
 *   ### What I Learned This Step header with ≥1 non-blank line after it.
 *
 * Skip when:
 *   - AGENT_TYPE not in matcher set
 *   - No active step log found
 *   - Agent's section header not found in log (defensive)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog, parseAgentType } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "subagent-retrospective-guard",
  event: "session_shutdown",
  matcher: "*",
} as const;

const MATCHED_AGENTS = new Set([
  "developer-phoenix-backend",
  "developer-phoenix-frontend",
  "reviewer-phoenix",
  "reviewer-static",
  "planner-phoenix",
  "planner-static",
]);

/** Find the most recently modified step log in codegen/logging/. */
function getActiveStepLog(projectDir: string): string | null {
  const loggingDir = path.join(projectDir, "codegen", "logging");
  if (!fs.existsSync(loggingDir)) return null;

  const logFiles = fs
    .readdirSync(loggingDir)
    .filter((f) => f.endsWith(".md") && !f.includes("progress"))
    .map((f) => ({
      name: f,
      mtime: fs.statSync(path.join(loggingDir, f)).mtimeMs,
    }))
    .sort((a, b) => b.mtime - a.mtime);

  if (logFiles.length === 0) return null;
  return path.join(loggingDir, logFiles[0].name);
}

/**
 * Extract the body of the LAST matching section block (heading to next ## heading or EOF).
 * Re-spawned passes log under "## <role> Section (pass N)" which prefix-matches the same
 * header via startsWith — reset accumulator on each match to keep only the final block.
 */
function extractSectionBody(content: string, header: string): string {
  const lines = content.split("\n");
  let result: string[] = [];
  let inSection = false;

  for (const line of lines) {
    if (line.startsWith(header)) {
      // New matching block (incl. "(pass N)") — reset to keep only the last.
      inSection = true;
      result = [];
      continue;
    }
    if (inSection && /^## /.test(line)) {
      inSection = false;
      continue;
    }
    if (inSection) {
      result.push(line);
    }
  }
  return result.join("\n");
}

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    debugLog("subagent-retrospective-guard", `agent=${agentType}`);

    // Only gate the matched roles.
    if (!MATCHED_AGENTS.has(agentType)) {
      debugLog(
        "subagent-retrospective-guard",
        `skip: agent=${agentType} not in matcher`,
      );
      return;
    }

    const projectDir = process.env["CWD"] ?? process.cwd();
    const logPath = getActiveStepLog(projectDir);

    if (!logPath) {
      debugLog("subagent-retrospective-guard", "skip: no active step log");
      return;
    }

    let logContent: string;
    try {
      logContent = fs.readFileSync(logPath, "utf8");
    } catch {
      debugLog("subagent-retrospective-guard", "skip: log unreadable");
      return;
    }

    debugLog(
      "subagent-retrospective-guard",
      `log=${logPath} agent=${agentType}`,
    );

    // All planner variants write their body under ## Plan.
    const sectionHeader = agentType.startsWith("planner")
      ? "## Plan"
      : `## ${agentType} Section`;

    // Check the section header exists.
    if (!logContent.includes(sectionHeader)) {
      debugLog(
        "subagent-retrospective-guard",
        `skip: no section header found for ${agentType}`,
      );
      return;
    }

    const sectionBody = extractSectionBody(logContent, sectionHeader);

    // Check for ### What I Learned This Step header.
    if (!sectionBody.includes("### What I Learned This Step")) {
      process.stderr.write(
        `[pi-enforcement:subagent-retrospective-guard] WARNING: ${agentType} returned but its ${sectionHeader} in the step log is missing the '### What I Learned This Step' block. Add this block to your section before finishing. Minimal acceptable content: '- nothing notable'. Step log: ${logPath}\n`,
      );
      return;
    }

    // Check at least one non-blank line follows the header.
    // Split on the header, then stop at the next ### heading or EOF.
    const learnedParts = sectionBody.split("### What I Learned This Step");
    const afterHeader = learnedParts.length > 1 ? learnedParts[1] : "";
    const nextH3Idx = afterHeader.indexOf("\n### ");
    const learnedBody =
      nextH3Idx >= 0 ? afterHeader.slice(0, nextH3Idx) : afterHeader;
    const hasContent = learnedBody.split("\n").some((line) => line.trim());

    if (!hasContent) {
      process.stderr.write(
        `[pi-enforcement:subagent-retrospective-guard] WARNING: ${agentType}'s '### What I Learned This Step' block in ${sectionHeader} exists but is empty. Add at least one bullet (minimum: '- nothing notable'). Step log: ${logPath}\n`,
      );
      return;
    }

    debugLog(
      "subagent-retrospective-guard",
      "PASS: retrospective block present and non-empty",
    );
  });
}
