/**
 * no-cat-pipe.ts — Pi enforcement: deny `cat FILE | head|tail|grep|less|more`.
 *
 * Mirrors: templates/shared/hooks/no-cat-pipe.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "no-cat-pipe",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("no-cat-pipe", `cmd=${command}`);

    if (/cat\s+[^|]*\|\s*(head|tail|grep|less|more)\b/.test(command)) {
      return deny(
        "Use Read tool with offset/limit instead of `cat | head/tail`. Use Grep tool instead of `cat | grep`. Truncation hides relevant lines.",
      );
    }
  });
}
