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
import {
  deny,
  parseAgentType,
  debugLog,
  stripQuoted,
  stripGitGlobalOpts,
  expandCommandIndirection,
} from "../lib/hook-helpers";

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

    // Fail-closed subject transform: strip single/double-quoted spans so a
    // forbidden git verb sitting inside a quoted remote-exec payload
    // (ssh host "git stash") or a quoted string argument
    // (grep -n 'git stash' file.sh) does not trigger this guard. A real,
    // unquoted, local git-verb invocation still matches and is still
    // denied. See stripQuoted() in hook-helpers.ts. Also normalize
    // interposed git global options (git -C <dir> commit, git
    // --git-dir=<x> add, …) so they cannot evade the verb match below —
    // see stripGitGlobalOpts() in hook-helpers.ts. Then
    // expandCommandIndirection() appends the body of any
    // bash/sh/zsh/source-referenced script on its own line (additive) so a
    // destructive verb hidden in a script written in a PRIOR Bash call is
    // scanned too — see hook-helpers.ts for the additive-only contract.
    const scan = expandCommandIndirection(stripGitGlobalOpts(stripQuoted(command)));

    if (/\bgit\s+add\b/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git add is forbidden for agent "${agentType}" — committer owns all git staging. Do not stage; leave changes in the working tree, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
    if (/\bgit\s+rm\b/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git rm is forbidden for agent "${agentType}" — committer owns all git staging. Do not stage; leave changes in the working tree, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
    if (/\bgit\s+mv\b/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git mv is forbidden for agent "${agentType}" — committer owns all git staging. Do not stage; leave changes in the working tree, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
    if (/\bgit\s+restore\b/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git restore is forbidden for agent "${agentType}" — this can DISCARD your own or another role's uncommitted working-tree edits (with or without --staged). To READ committed content use \`git show HEAD:<path>\`; to change a file you own use Edit/Write; a revert belongs to the committer. Do not restore; leave changes in the working tree, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
    if (/\bgit\s+(checkout|switch)\b/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git checkout/switch is forbidden for agent "${agentType}" — checkout of a path can DISCARD uncommitted working-tree edits (yours or another role's), and branch switches belong to the committer. To READ committed content use \`git show HEAD:<path>\`; to change a file you own use Edit/Write. Do not checkout/switch; leave the working tree as-is, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
    if (/\bgit\s+clean\b/.test(scan) && !/\bgit\s+clean\b.*(-n\b|--dry-run\b)/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git clean (without -n/--dry-run) is forbidden for agent "${agentType}" — it PERMANENTLY DELETES untracked files, including another role's uncommitted new files. Use \`git clean -n\` to preview only, or ask the committer. Do not clean; leave the working tree as-is, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
    if (/\bgit\s+commit(?:[\s;&|]|$)/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git commit forbidden for agent "${agentType}" — committer owns commit creation (see CLAUDE.md "NEVER Commit Directly"). Do not commit; leave changes uncommitted in the working tree, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
    if (/\bgit\s+rebase\b/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git rebase forbidden for agent "${agentType}" — committer owns history. Do not rebase; leave the branch as-is, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
    if (/\bgit\s+cherry-pick\b/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git cherry-pick forbidden for agent "${agentType}" — committer owns history. Do not cherry-pick; leave the branch as-is, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
    if (/\bgit\s+revert\b/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git revert forbidden for agent "${agentType}" — committer owns history. Do not revert; leave the branch as-is, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
    if (/\bgit\s+merge\b/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git merge forbidden for agent "${agentType}" — committer owns history. Do not merge; leave the branch as-is, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
    if (/\bgit\s+reset\b.*--(hard|merge|keep)\b/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git reset --hard/--merge/--keep forbidden for agent "${agentType}" — destructive, committer owns history. Do not reset; leave the working tree as-is, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }

    if (/\bgit\s+reset\b/.test(scan) && !/\bgit\s+reset\b.*--(hard|merge|keep)\b/.test(scan)) {
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
    if (/\bgit\s+push\b.*(--force(-with-lease)?|\s-f(\s|$))/.test(scan)) {
      return deny(
        `BLOCKED by pre-commit-guard: git push --force forbidden for agent "${agentType}" — committer owns push discipline. Do not force-push; leave the branch as-is, the loop's committer step runs after you — finish your remaining in-role work and stop.`,
      );
    }
  });
}
