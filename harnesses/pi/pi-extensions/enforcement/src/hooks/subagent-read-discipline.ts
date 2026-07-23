/**
 * subagent-read-discipline.ts — Pi enforcement: gate Read on context/pitch
 * files for named subagents.
 *
 * Mirrors: harnesses/claude/hooks/subagent-read-discipline.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: read
 *
 * Rules:
 *   planner-*       → allow all (planner owns context AND pitch reads)
 *   context-curator → allow all (curator writes context post-reviewer)
 *   committer       → deny PROJECT_CONTEXT.md, context/*.md, codegen/pitches/**
 *   developer-*     → deny codegen/pitches/** always (plan is self-contained);
 *                     deny PROJECT_CONTEXT.md always;
 *                     context/*.md allowed ONLY if listed in the PLANNER's
 *                     typed {"ev":"files_to_touch",...} event in the active
 *                     cycle log
 *   reviewer-*      → deny codegen/pitches/** always;
 *                     deny PROJECT_CONTEXT.md always;
 *                     context/*.md allowed ONLY if listed in the DEVELOPER's
 *                     typed {"ev":"files_modified",...} event in the active
 *                     cycle log
 *   (other / empty) → pass through (orchestrator handled by
 *                     orchestrator-read-discipline.ts)
 *
 * The field is read from its AUTHOR's event — never from the calling role's
 * own event; never re-parsed out of free-form body prose.
 *
 * Fail-open: if the active step log is missing/unreadable, allow the Read
 * (avoids false-negatives during session initialisation — same as the bash
 * twin's ANTI-WEDGE FAIL-OPEN carve-out).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as fs from "fs";
import { deny, repoRelative, debugLog, getActiveStepLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "subagent-read-discipline",
  event: "tool_call",
  matcher: "read",
} as const;

function filePathOf(input: unknown): string {
  const rec = input as { path?: string; file_path?: string };
  return rec.path ?? rec.file_path ?? "";
}

/** Read the AUTHOR's typed event array from the active cycle log JSONL. */
function readEventFiles(
  stepLog: string,
  ev: "files_to_touch" | "files_modified",
  rolePrefix: string,
): string[] {
  let text: string;
  try {
    text = fs.readFileSync(stepLog, "utf8");
  } catch {
    return [];
  }
  const files: string[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let obj: { ev?: string; role?: string; files?: string[] };
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (obj.ev === ev && typeof obj.role === "string" && obj.role.startsWith(rolePrefix)) {
      if (Array.isArray(obj.files)) files.push(...obj.files);
    }
  }
  return files;
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "read") return;

    const agentType = process.env["AGENT_TYPE"] ?? "";
    if (!agentType) return; // Only named subagents are gated.

    const filePath = filePathOf(event.input);
    if (!filePath) return;

    const relPath = repoRelative(filePath);
    const bn = relPath.split("/").pop() ?? relPath;

    const isProjectContext = bn === "PROJECT_CONTEXT.md";
    const isContextDir = /^context\//.test(relPath);
    const isPitch = /^codegen\/pitches\//.test(relPath);

    if (!isProjectContext && !isContextDir && !isPitch) return;

    debugLog(
      "subagent-read-discipline",
      `agent_type=${agentType} file=${filePath}`,
    );

    if (agentType.startsWith("planner-")) return;
    if (agentType === "context-curator") return;

    if (agentType === "committer") {
      if (isPitch) {
        return deny(
          "Committer cannot read the pitch — derive commit message from git diff only.",
        );
      }
      if (isProjectContext) {
        return deny(
          "Committer cannot read PROJECT_CONTEXT.md. Derive commit message from git diff only.",
        );
      }
      if (isContextDir) {
        return deny(
          "Committer cannot read context/*.md. Derive commit message from git diff only.",
        );
      }
      return;
    }

    if (agentType.startsWith("developer-")) {
      if (isPitch) {
        return deny(
          "Developer cannot read the pitch — when a ## Plan is present it is self-contained, use it from the session log; when no ## Plan is present, the pitch text is already inlined in your delegation prompt.",
        );
      }
      if (isProjectContext) {
        return deny(
          "Developer cannot read PROJECT_CONTEXT.md for orientation. When a ## Plan is present it is self-contained — use it from the active step log; when absent, the pitch text already inlined in your prompt is the complete scope.",
        );
      }
      if (isContextDir) {
        const stepLog = getActiveStepLog(process.cwd());
        if (!stepLog || !fs.existsSync(stepLog)) return; // ANTI-WEDGE FAIL-OPEN.
        const files = readEventFiles(stepLog, "files_to_touch", "planner");
        if (files.includes(relPath)) return;
        return deny(
          `Developer cannot read ${filePath} for orientation. Read context/*.md only when the path appears in planner's files_to_touch event as an (EDIT) or (NEW) target.`,
        );
      }
      return;
    }

    if (agentType.startsWith("reviewer-")) {
      if (isPitch) {
        return deny(
          "Reviewer cannot read the pitch — review against ## Plan (when present) and ## Files Modified in the active step log; when no ## Plan was threaded (plan-less stack), report plan-fulfillment checks N/A rather than reading the pitch.",
        );
      }
      if (isProjectContext) {
        return deny(
          "Reviewer cannot read PROJECT_CONTEXT.md. Check plan fulfillment via ## Plan Goal line in active step log when present; when absent, report N/A — no ## Plan in the active step log (plan-less stack).",
        );
      }
      if (isContextDir) {
        const stepLog = getActiveStepLog(process.cwd());
        if (!stepLog || !fs.existsSync(stepLog)) return; // ANTI-WEDGE FAIL-OPEN.
        const files = readEventFiles(stepLog, "files_modified", "developer");
        if (files.includes(relPath)) return;
        return deny(
          `Reviewer cannot read ${filePath} — it is not listed in developer's files_modified event. Review only files that developer modified.`,
        );
      }
      return;
    }

    // Unknown AGENT_TYPE — pass through.
  });
}
