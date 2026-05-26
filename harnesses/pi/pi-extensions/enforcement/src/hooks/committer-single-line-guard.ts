/**
 * committer-single-line-guard.ts — Pi enforcement: block git commits with
 * multi-line -m payloads.
 *
 * Mirrors: templates/shared/hooks/committer-single-line-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "committer-single-line-guard",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    if (parseAgentType() !== "committer") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("committer-single-line-guard", `cmd=${command}`);

    if (!/\bgit\s+commit\b/.test(command)) return;

    // Deny if command contains actual newline character
    if (command.includes("\n")) {
      return deny(
        "BLOCKED by committer-single-line-guard: git commit command contains actual newline. Use a single-line subject only.",
      );
    }

    // Deny if command contains literal \n (backslash + n)
    if (command.includes("\\n")) {
      return deny(
        "BLOCKED by committer-single-line-guard: commit -m payload contains literal \\n. Use a single-line subject only.",
      );
    }
  });
}
