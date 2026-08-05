/**
 * usage-rules-grep-guard.ts — Pi enforcement: block every agent except the
 * developer from scanning codegen/usage_rules/.
 *
 * Mirrors: harnesses/claude/hooks/usage-rules-grep-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash, grep
 *
 * Blocks every agent except the developer from grepping/scanning
 * codegen/usage_rules/. Only the developer may scan the full corpus — every
 * other agent must read only files cited by codegen/usage_rules/INDEX.md.
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
    if (/^developer-/.test(agentType)) return;

    debugLog(
      "usage-rules-grep-guard",
      `tool=${event.toolName} agent=${agentType}`,
    );

    if (event.toolName === "bash") {
      const command: string =
        (event.input as { command?: string }).command ?? "";
      if (/(grep|rg)\s+.*codegen\/usage_rules\//.test(command)) {
        return deny(
          "BLOCKED by usage-rules-grep-guard: only the developer may scan codegen/usage_rules/. Read codegen/usage_rules/INDEX.md, look up the deps you are touching, and Read at most 5 cited files.",
        );
      }
    }

    if (event.toolName === "grep") {
      const grepPath: string = (event.input as { path?: string }).path ?? "";
      if (grepPath.includes("codegen/usage_rules")) {
        return deny(
          "BLOCKED by usage-rules-grep-guard: only the developer may scan codegen/usage_rules/. Read codegen/usage_rules/INDEX.md, look up the deps you are touching, and Read at most 5 cited files.",
        );
      }
    }
  });
}
