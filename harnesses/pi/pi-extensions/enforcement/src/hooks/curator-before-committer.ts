/**
 * curator-before-committer.ts — Pi enforcement: block committer spawn before
 * context-curator has run.
 *
 * Mirrors: harnesses/claude/hooks/curator-before-committer.sh
 * Event: tool_call
 * Matcher: subagent
 *
 * Logic:
 *   If subagent_type == "committer"
 *     AND session log has a ## reviewer-* Section
 *     AND session log has NO ## context-curator Section
 *   → deny with explanation
 *
 * Fail-open: if no session log found (path absent), allow. If the log path
 * resolves but the read throws (present-but-unreadable), deny — an unreadable
 * log cannot verify the curator ran, so allowing here would silently skip
 * the gate.
 * All other subagent types: allow unconditionally.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, getActiveStepLog } from "../lib/hook-helpers";
import * as fs from "node:fs";

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

    let logContent: string;
    try {
      logContent = fs.readFileSync(logPath, "utf8");
    } catch (e) {
      debugLog(
        "curator-before-committer",
        `deny: log path resolved but unreadable: ${(e as Error).message}`,
      );
      return deny(
        `BLOCKED by curator-before-committer: step log at ${logPath} was located but could not be read (${(e as Error).message}). Cannot verify context-curator ran before committer — fix the log read error first.`,
      );
    }

    const hasReviewer =
      /^## reviewer-.+ Section|^## reviewer-phoenix Section|^## reviewer-static Section/m.test(
        logContent,
      );
    const hasCurator = /^## context-curator Section/m.test(logContent);

    debugLog(
      "curator-before-committer",
      `hasReviewer=${hasReviewer} hasCurator=${hasCurator}`,
    );

    if (hasReviewer && !hasCurator) {
      return deny(
        "BLOCKED: context-curator must run before committer. Reviewer ran, curator has not. Delegate to context-curator first.",
      );
    }
  });
}
