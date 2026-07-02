/**
 * pre-commit-guard.ts — Pi enforcement: block state-modifying git commands for
 * non-committer agents.
 *
 * Mirrors: templates/shared/hooks/pre-commit-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
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

    // codegen-log carve-out (mirrors session-log-writer-only.ts): every
    // role's session-log section body is piped into codegen-log, so the
    // piped body is arbitrary role-authored prose that may legitimately
    // contain git verb tokens. Exit-allow BEFORE the git-verb scans below so
    // codegen-log invocations are never denied by prose in their own piped
    // body. Bare history-mutating git commands remain denied below.
    if (/(^|[\s/])codegen-log\b/.test(command)) return;

    if (/\bgit\s+add\b/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git add is forbidden for agent "${agentType}" — committer owns all git staging (delegate to committer)`,
      );
    }
    if (/\bgit\s+rm\b/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git rm is forbidden for agent "${agentType}" — committer owns all git staging (delegate to committer)`,
      );
    }
    if (/\bgit\s+mv\b/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git mv is forbidden for agent "${agentType}" — committer owns all git staging (delegate to committer)`,
      );
    }
    if (/\bgit\s+restore\b.*--staged\b/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git restore --staged is forbidden for agent "${agentType}" — committer owns all git staging (delegate to committer)`,
      );
    }
    if (/\bgit\s+stash\b/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git stash is forbidden for agent "${agentType}" — committer owns all git staging (delegate to committer)`,
      );
    }
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

    if (/\bgit\s+reset\b/.test(command) && !/\bgit\s+reset\b.*--hard\b/.test(command)) {
      const buildStartTs = process.env["CODEGEN_BUILD_START_TS"] ?? "";
      if (buildStartTs) {
        const projectDir = process.env["CWD"] ?? process.cwd();
        try {
          const headCt = execSync("git -C \"" + projectDir + "\" log -1 --format=%ct", {
            encoding: "utf8",
          }).trim();
          if (headCt && Number(headCt) < Number(buildStartTs)) {
            return deny(
              `BLOCKED by pre-commit-guard: git reset would rewrite a commit from BEFORE this build cycle (HEAD commit time ${headCt} < cycle start ${buildStartTs}). That commit belongs to a prior cycle and is immutable to this one. To allow (emergency only): set COMMITTER_ALLOW_MULTI=1`,
            );
          }
        } catch {
          // Fail open: if HEAD time cannot be read, preserve the existing allow.
        }
      }
    }
    if (/\bgit\s+push\b.*(--force(-with-lease)?|\s-f(\s|$))/.test(command)) {
      return deny(
        `BLOCKED by pre-commit-guard: git push --force forbidden for agent "${agentType}" — committer owns push discipline`,
      );
    }
  });
}
