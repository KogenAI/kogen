/**
 * committer-no-head-move-reset.ts — Pi enforcement: deny a HEAD-moving git
 * reset from the committer agent.
 *
 * Mirrors: harnesses/claude/hooks/committer-no-head-move-reset.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * Denies any `git reset` invocation from the committer agent that would move
 * HEAD to a different commit (e.g. `git reset HEAD~1`, `--hard`/`--soft`/
 * `--keep`/`--merge`, or any targeted commit-ish). Such a reset can silently
 * drop an already-committed, possibly already-pushed commit from a prior
 * cycle; a subsequent `git add -A && git commit` then folds that commit's
 * diff into a new one, orphaning the original from the branch.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog, isCodegenLogWrite } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "committer-no-head-move-reset",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    if (parseAgentType() !== "committer") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("committer-no-head-move-reset", `cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match.
    if (isCodegenLogWrite(command)) return;

    if (!/\bgit\s+reset\b/.test(command)) return;

    if (process.env["COMMITTER_ALLOW_MULTI"] === "1") {
      debugLog("committer-no-head-move-reset", "allow: COMMITTER_ALLOW_MULTI=1");
      return;
    }

    // Mode flags that always move HEAD regardless of the target.
    if (/--(soft|hard|keep|merge)\b/.test(command)) {
      return deny(
        "BLOCKED by committer-no-head-move-reset: 'git reset' with a HEAD-moving mode flag (--soft/--hard/--keep/--merge) is forbidden. This can silently orphan a prior cycle's already-committed commit. To fix THIS cycle's commit use: git commit --amend. Emergency override: COMMITTER_ALLOW_MULTI=1",
      );
    }

    // Extract the reset invocation's arguments (everything after 'git reset'
    // up to the next '&&', '||', ';', or '|', or end of string) to scope ref
    // detection to this specific invocation, not the whole command line.
    const afterReset = command.replace(/^.*\bgit\s+reset\b/, "");
    const resetArgs = afterReset.replace(/[&|;].*$/, "");

    // Strip a `-- <path...>` path-scoped suffix — anything after a bare `--`
    // is a path, never a commit-ish, and must not trigger ref detection.
    const resetArgsNoPaths = resetArgs.replace(/\s--\s.*$/, "");

    const trimmed = resetArgsNoPaths.trim();

    // No target token left (bare `git reset`) — allowed, HEAD unmoved.
    if (trimmed === "") {
      debugLog("committer-no-head-move-reset", "allow: bare git reset (no target)");
      return;
    }

    // Bare `HEAD` with nothing else is a no-op unstage — allowed.
    if (/^HEAD$/.test(trimmed)) {
      debugLog("committer-no-head-move-reset", "allow: git reset HEAD (no-op unstage)");
      return;
    }

    // Any remaining non-empty token set here is a target commit-ish that is
    // not bare HEAD: HEAD~N, HEAD^, @{...}, a hex SHA, or a branch/tag/ref
    // name. All of these move HEAD to a different commit — deny.
    return deny(
      `BLOCKED by committer-no-head-move-reset: 'git reset' targeting a commit-ish other than bare HEAD is forbidden (detected: ${trimmed}). This can silently orphan a prior cycle's already-committed commit — a subsequent commit would fold that commit's diff into a new one, dropping it from the branch. Allowed forms: bare 'git reset', 'git reset HEAD', or 'git reset -- <path>' (path-scoped unstage). To fix THIS cycle's commit use: git commit --amend. Emergency override: COMMITTER_ALLOW_MULTI=1`,
    );
  });
}
