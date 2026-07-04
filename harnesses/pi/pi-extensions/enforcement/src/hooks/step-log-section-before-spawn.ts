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
import { deny, debugLog, getActiveStepLog } from "../lib/hook-helpers";
import * as fs from "node:fs";

export const HANDLER_META = {
  name: "step-log-section-before-spawn",
  event: "tool_call",
  matcher: "subagent",
} as const;

/** Map subagent type to the expected header string. */
function expectedHeader(subagentType: string): string {
  if (subagentType.startsWith("planner")) {
    return "## Plan";
  }
  return `## ${subagentType} Section`;
}

/**
 * Return true when the named section has at least one non-heading body line,
 * excluding the "### What I Learned This Step" retrospective block (which is
 * not real content on its own). Any other "### " line (e.g. a verdict
 * marker like "### FINAL VERDICT — APPROVED") counts as body content.
 */
function sectionHasBody(logContent: string, header: string): boolean {
  const lines = logContent.split("\n");
  const headerIdx = lines.findIndex((l) => l === header);
  if (headerIdx === -1) return false;

  let inRetro = false;
  for (let i = headerIdx + 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith("## ")) break;
    if (line.startsWith("### What I Learned")) {
      inRetro = true;
      continue;
    }
    if (inRetro && line.trim() === "") continue;
    if (inRetro && /^\s*[-*]/.test(line)) continue;
    if (inRetro) inRetro = false;
    if (line.trim() === "") continue;
    return true;
  }

  return false;
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
    const projectDir = process.env["CWD"] ?? process.cwd();
    const logPath = getActiveStepLog(projectDir);

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
      // Pi has no transcript access so we cannot determine the authoritative
      // step log from transcript context. We read the most recently modified
      // log, which may differ from the active session log.
      //
      // Fail closed on header-only sections: the next role may not spawn until
      // the prior required section contains at least one non-heading body line.
      if (!sectionHasBody(logContent, need)) {
        return deny(
          `BLOCKED: '${need}' exists but has no non-heading body content. Populate the section before spawning ${subagentType}.`,
        );
      }

      debugLog("step-log-section-before-spawn", "allow: header present");
      return;
    }

    return deny(
      `BLOCKED: missing section header in step log before spawning ${subagentType}. Edit the step log to append '${need}' immediately before this Agent() call, then retry.`,
    );
  });
}
