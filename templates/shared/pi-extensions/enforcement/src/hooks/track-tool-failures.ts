/**
 * track-tool-failures.ts — Pi enforcement: telemetry — track tool failures
 * (observe only, no blocking).
 *
 * Mirrors: templates/shared/hooks/track-tool-failures.sh
 * Event: tool_result with isError=true (PostToolUseFailure equivalent)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parseAgentType, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "track-tool-failures",
  event: "tool_result",
  matcher: "*",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_result", async (event) => {
    if (!event.isError) return;

    const agentType = parseAgentType();
    debugLog(
      "track-tool-failures",
      `tool=${event.toolName} agent=${agentType} error=true`
    );

    // Telemetry only — no blocking
  });
}
