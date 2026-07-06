/**
 * curator-before-committer.ts — Pi enforcement: block committer spawn before
 * context-curator has run.
 *
 * Mirrors: harnesses/claude/hooks/curator-before-committer.sh
 * Event: tool_call
 * Matcher: subagent
 *
 * Logic (cycle-state.json is the source of truth, not session-log content —
 * matches the bash sibling's migration off markdown-header scanning):
 *   If subagent_type == "committer"
 *     AND cycle-state.json state == "REVIEWED"
 *   → deny with explanation
 *
 * Fail-open: if no active step log, or no cycle-state.json / state absent,
 * allow (cannot determine state). All other subagent types: allow
 * unconditionally.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, getActiveStepLog, getCycleState } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "curator-before-committer",
  event: "tool_call",
  matcher: "subagent",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "subagent") return;

    const subagentType: string =
      (event.input as { agent?: string; subagent_type?: string }).agent ??
      (event.input as { agent?: string; subagent_type?: string })
        .subagent_type ??
      "";

    debugLog("curator-before-committer", `subagent_type=${subagentType}`);

    // Only inspect committer spawns.
    if (subagentType !== "committer") return;

    // Locate active step log — fail-open if missing.
    const projectDir = process.env["CWD"] ?? process.cwd();
    const logPath = getActiveStepLog(projectDir);
    if (!logPath) {
      debugLog("curator-before-committer", "fail-open: no active step log");
      return;
    }

    debugLog("curator-before-committer", `log=${logPath}`);

    const cycleState = getCycleState(projectDir);
    const csState = cycleState?.state ?? "";

    debugLog("curator-before-committer", `cs_state=${csState}`);

    // Block only when cycle-state is REVIEWED (reviewer ran, curator has not).
    if (csState === "REVIEWED") {
      return deny(
        "BLOCKED: context-curator must run before committer. Reviewer ran (cycle-state=REVIEWED), curator has not. Delegate to context-curator first.",
      );
    }
  });
}
