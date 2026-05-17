/**
 * reviewer-guard.ts — Pi enforcement: restrict reviewers to read-only.
 *
 * Mirrors: templates/shared/hooks/reviewer-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash, write, edit
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "reviewer-guard",
  event: "tool_call",
  matcher: "bash|write|edit",
} as const;

const REVIEWER_AGENTS = new Set(["reviewer-phoenix", "reviewer-static"]);

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    const agentType = parseAgentType();
    if (!REVIEWER_AGENTS.has(agentType)) return;

    debugLog("reviewer-guard", `tool=${event.toolName} agent=${agentType}`);

    if (event.toolName === "write" || event.toolName === "edit") {
      return deny(
        `BLOCKED by reviewer-guard: reviewer "${agentType}" is read-only — no Edit/Write allowed.`
      );
    }

    if (event.toolName === "bash") {
      return deny(
        `BLOCKED by reviewer-guard: reviewer "${agentType}" may not run Bash — read-only investigation only.`
      );
    }
  });
}
