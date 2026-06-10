/**
 * step-log-section-before-spawn.ts — Pi enforcement: require step log +
 * section header before any subagent spawn.
 *
 * Mirrors: harnesses/claude/hooks/step-log-section-before-spawn.sh
 * Event: tool_call
 * Matcher: subagent (BLOCKING via deny())
 *
 * Logic:
 *   Read subagent_type from tool input.
 *   Map planner-* → "## Plan"; anything else → "## <type> Section".
 *   Locate active step log via getActiveStepLog().
 *   If no log found → deny ("create step log FIRST")
 *   If log exists but expected header absent → deny (naming the missing header)
 *   Else → allow
 *
 * Fail-open: if log dir is missing or unreadable, allow.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "step-log-section-before-spawn",
  event: "tool_call",
  matcher: "subagent",
} as const;

/** Find the most recently modified step log in codegen/logging/. */
function getActiveStepLog(): string | null {
  const projectDir = process.env["CWD"] ?? process.cwd();
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

/** Map subagent type to the expected header string. */
function expectedHeader(subagentType: string): string {
  if (subagentType.startsWith("planner")) {
    return "## Plan";
  }
  return `## ${subagentType} Section`;
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "subagent") return;

    const role =
      process.env["CLAUDE_ROLE"] || process.env["PI_ROLE"] || "";
    if (["debug", "shape", "ops"].includes(role)) return;

    const subagentType: string =
      (event.input as { agent?: string; subagent_type?: string }).agent ??
      (event.input as { agent?: string; subagent_type?: string })
        .subagent_type ??
      "";

    debugLog("step-log-section-before-spawn", `subagent_type=${subagentType}`);

    const need = expectedHeader(subagentType);
    debugLog("step-log-section-before-spawn", `need=${need}`);

    // Locate active step log — fail-open if missing.
    const logPath = getActiveStepLog();

    if (!logPath) {
      debugLog(
        "step-log-section-before-spawn",
        "no step log found — deny (create log first)",
      );
      return deny(
        `BLOCKED: no step log found. Create the step log FIRST before spawning ${subagentType}. Step 0 is non-negotiable: Write the step log skeleton, THEN insert the ${need} header, THEN spawn.`,
      );
    }

    let logContent: string;
    try {
      logContent = fs.readFileSync(logPath, "utf8");
    } catch {
      debugLog(
        "step-log-section-before-spawn",
        "fail-open: could not read log",
      );
      return;
    }

    debugLog("step-log-section-before-spawn", `log=${logPath}`);

    if (logContent.includes(need)) {
      debugLog("step-log-section-before-spawn", "allow: header present");
      return;
    }

    return deny(
      `BLOCKED: missing section header in step log before spawning ${subagentType}. Edit the step log to append '${need}' immediately before this Agent() call, then retry.`,
    );
  });
}
