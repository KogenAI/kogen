/**
 * track-subagent-edits.ts — Pi enforcement: telemetry — track edits made
 * by subagents (observe only, no blocking).
 *
 * Mirrors: templates/shared/hooks/track-subagent-edits.sh
 * Event: tool_call (PreToolUse equivalent, observe only)
 * Matcher: write, edit
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parseAgentType, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "track-subagent-edits",
  event: "tool_call",
  matcher: "edit|write",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return;

    const agentType = parseAgentType();
    const filePath: string =
      (event.input as { path?: string; file_path?: string }).path ??
      (event.input as { path?: string; file_path?: string }).file_path ??
      "";

    debugLog(
      "track-subagent-edits",
      `tool=${event.toolName} agent=${agentType} file=${filePath}`
    );

    // Telemetry only — no blocking
  });
}
