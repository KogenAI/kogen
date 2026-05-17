/**
 * session-log-section-integrity.ts — Pi enforcement: assert session log
 * section headers are included when a subagent edits/writes a session log.
 *
 * Mirrors: templates/shared/hooks/session-log-section-integrity.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: write, edit
 *
 * When a non-planner/non-orchestrator subagent edits or writes a session log
 * file (codegen/logging/*.md), the new content must include
 * "## <agentType> Section". Exception: if the header already exists in the
 * file (follow-up edit by the same agent), allow unconditionally.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";

export const HANDLER_META = {
  name: "session-log-section-integrity",
  event: "tool_call",
  matcher: "write|edit",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "write" && event.toolName !== "edit") return;

    const agentType = parseAgentType();

    // Orchestrator (empty agent_type) and planner bypass — they write ## Plan, not ## X Section
    if (
      !agentType ||
      agentType === "planner" ||
      agentType.startsWith("planner-")
    )
      return;

    const filePath: string =
      (event.input as { path?: string; file_path?: string }).path ??
      (event.input as { path?: string; file_path?: string }).file_path ??
      "";

    if (!filePath) return;

    // Only gate session log files
    if (!filePath.includes("codegen/logging/") || !filePath.endsWith(".md"))
      return;

    debugLog(
      "session-log-section-integrity",
      `tool=${event.toolName} agent=${agentType} file=${filePath}`,
    );

    const expectedHeader = `## ${agentType} Section`;

    // For Edit: if the file already exists and contains the header, allow (follow-up edit)
    if (event.toolName === "edit") {
      if (fs.existsSync(filePath)) {
        const existing = fs.readFileSync(filePath, "utf8");
        if (existing.includes(expectedHeader)) return; // follow-up, allowed
        // File exists but no header yet — check new_string
      } else {
        // File doesn't exist yet — first write via edit, allow
        return;
      }
    }

    // Get the payload being written
    let payload = "";
    if (event.toolName === "edit") {
      payload = (event.input as { new_string?: string }).new_string ?? "";
    } else if (event.toolName === "write") {
      payload = (event.input as { content?: string }).content ?? "";
    }

    if (payload.includes(expectedHeader)) return;

    return deny(
      `BLOCKED by session-log-section-integrity: ${event.toolName} on ${filePath} from ${agentType} must include "${expectedHeader}" in the payload.`,
    );
  });
}
