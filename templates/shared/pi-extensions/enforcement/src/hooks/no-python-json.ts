/**
 * no-python-json.ts — Pi enforcement: deny inline python JSON parsing.
 *
 * Mirrors: templates/shared/hooks/no-python-json.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "no-python-json",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("no-python-json", `cmd=${command}`);

    if (
      /\bpython3?\b[^|;&]*-c\b/.test(command) &&
      /import\s+json|json\.load/.test(command)
    ) {
      return deny(
        "Don't parse JSON with python3 -c. Use Read tool — JSON files render readably. Inline python parsing is a thrash anti-pattern (see token-budget rule).",
      );
    }
  });
}
