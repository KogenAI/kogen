/**
 * pre-commit-guard.ts — Pi enforcement: block state-modifying git commands for
 * non-committer agents.
 *
 * Mirrors: templates/shared/hooks/pre-commit-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "pre-commit-guard",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const agentType = parseAgentType();
    if (agentType === "committer") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("pre-commit-guard", `agent=${agentType} cmd=${command}`);

    if (/\bgit\s+commit\b/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git commit forbidden for agent "${agentType}" — committer owns commit creation (see CLAUDE.md "NEVER Commit Directly")`,
      );
    }
    if (/\bgit\s+rebase\b/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git rebase forbidden for agent "${agentType}" — committer owns history`,
      );
    }
    if (/\bgit\s+cherry-pick\b/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git cherry-pick forbidden for agent "${agentType}" — committer owns history`,
      );
    }
    if (/\bgit\s+revert\b/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git revert forbidden for agent "${agentType}" — committer owns history`,
      );
    }
    if (/\bgit\s+merge\b/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git merge forbidden for agent "${agentType}" — committer owns history`,
      );
    }
    if (/\bgit\s+reset\b.*--hard\b/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git reset --hard forbidden for agent "${agentType}" — destructive (use stash or committer)`,
      );
    }
    if (/\bgit\s+push\b.*(--force(-with-lease)?|\s-f(\s|$))/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git push --force forbidden for agent "${agentType}" — committer owns push discipline`,
      );
    }
  });
}
