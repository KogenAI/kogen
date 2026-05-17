/**
 * no-git-stash.ts — Pi enforcement: deny `git stash` invocations.
 *
 * Mirrors: templates/shared/hooks/no-git-stash.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "no-git-stash",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string =
      (event.input as { command?: string }).command ?? "";
    debugLog("no-git-stash", `cmd=${command}`);

    if (/\bgit\s+stash\b/.test(command)) {
      return deny(
        "git stash forbidden. Commit WIP to a scratch branch or use worktrees. Stash hides work from orchestrator + reviewer."
      );
    }
  });
}
