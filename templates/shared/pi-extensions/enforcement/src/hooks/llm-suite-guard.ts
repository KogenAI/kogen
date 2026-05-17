/**
 * llm-suite-guard.ts — Pi enforcement: deny bare `make llm` / `make llm-phoenix`
 * for developer-* agents.
 *
 * Mirrors: templates/shared/hooks/llm-suite-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "llm-suite-guard",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const agentType = parseAgentType();
    if (!/^developer-/.test(agentType)) return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("llm-suite-guard", `agent=${agentType} cmd=${command}`);

    if (/^\s*make\s+(llm|llm-phoenix)(\s|$)/.test(command)) {
      return deny(
        "Devs MUST NOT run the full LLM suite. Use `make llm-single FILE=<path>` to iterate on one file. The gate runs `make llm`/`make llm-phoenix` after you exit.",
      );
    }
  });
}
