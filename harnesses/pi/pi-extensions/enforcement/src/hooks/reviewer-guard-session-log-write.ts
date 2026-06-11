/**
 * reviewer-guard-session-log-write.ts — Pi enforcement: reviewer may only edit canonical session log files (allowlist).
 *
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: Write|Edit
 *
 * GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
 * Edit registry.yaml and run `make install` to regenerate.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, repoRelative } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "reviewer-guard-session-log-write",
  event: "tool_call",
  matcher: "write|edit",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (!(event.toolName === "write" || event.toolName === "edit")) return;

    const agentType = process.env["AGENT_TYPE"] ?? "";
    if (!(agentType === "reviewer-phoenix" || agentType === "reviewer-static")) return;

    const filePath: string = (event.input as { file_path?: string }).file_path ?? "";
    debugLog("reviewer-guard-session-log-write", `file=${filePath}`);

    const rel = repoRelative(filePath);
    if (/codegen\/logging\/[0-9]{8}_[0-9]{6}(_[a-z0-9_-]+)?_(session|step[0-9]+_[a-z0-9_-]+)\.md$/.test(rel)) {
      return;
    }

    return deny(
      "BLOCKED by reviewer-guard-session-log-write: reviewer may only write to canonical session logs: " + filePath,
    );
  });
}
