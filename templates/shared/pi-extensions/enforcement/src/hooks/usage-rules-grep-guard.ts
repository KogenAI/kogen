/**
 * usage-rules-grep-guard.ts — Pi enforcement: block non-planner agents from
 * scanning codegen/usage_rules/.
 *
 * Mirrors: templates/shared/hooks/usage-rules-grep-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash, grep
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "usage-rules-grep-guard",
  event: "tool_call",
  matcher: "bash|grep",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash" && event.toolName !== "grep") return;

    const agentType = parseAgentType();
    if (agentType === "planner" || /^planner-/.test(agentType)) return;

    debugLog(
      "usage-rules-grep-guard",
      `tool=${event.toolName} agent=${agentType}`,
    );

    if (event.toolName === "bash") {
      const command: string =
        (event.input as { command?: string }).command ?? "";
      if (/(grep|rg)\s+.*codegen\/usage_rules\//.test(command)) {
        return deny(
          'BLOCKED by usage-rules-grep-guard: only planner may scan codegen/usage_rules/. Read only the files cited in the plan\'s "Usage rules for implementer:" field.',
        );
      }
    }

    if (event.toolName === "grep") {
      const grepPath: string = (event.input as { path?: string }).path ?? "";
      if (grepPath.includes("codegen/usage_rules")) {
        return deny(
          'BLOCKED by usage-rules-grep-guard: only planner may scan codegen/usage_rules/. Read only the files cited in the plan\'s "Usage rules for implementer:" field.',
        );
      }
    }
  });
}
