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
 * Fail-open: if no session log found, allow.
 * All other subagent types: allow unconditionally.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "curator-before-committer",
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
    const logPath = getActiveStepLog();
    if (!logPath) {
      debugLog("curator-before-committer", "fail-open: no active step log");
      return;
    }

    let logContent: string;
    try {
      logContent = fs.readFileSync(logPath, "utf8");
    } catch {
      debugLog("curator-before-committer", "fail-open: could not read log");
      return;
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
