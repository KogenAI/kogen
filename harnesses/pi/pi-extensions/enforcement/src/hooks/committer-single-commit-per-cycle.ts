/**
 * committer-single-commit-per-cycle.ts — Pi enforcement: deny a second non-amend
 * git commit from the committer agent within the same build cycle.
 *
 * Mirrors: harnesses/claude/hooks/committer-single-commit-per-cycle.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * Counts commits reachable from HEAD but not from CODEGEN_CYCLE_BASE_SHA
 * (the SHA captured ONCE at cycle start, before any role ran — identical
 * across every role's env, unlike a per-role timestamp). If ≥1 such commit
 * exists and the incoming command is not --amend, the command is denied.
 * This also catches a commit made by an EARLIER role in the same cycle.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  deny,
  parseAgentType,
  debugLog,
  isCodegenLogWrite,
} from "../lib/hook-helpers";
import { execFileSync } from "node:child_process";

function gitLog(projectDir: string, args: string[]): string {
  try {
    return execFileSync("git", ["-C", projectDir, ...args], {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return "";
  }
}

// gitRevListCount() — number of commits reachable from HEAD but not from
// baseSha, via `git rev-list --count <baseSha>..HEAD`. Returns NaN on any
// git failure (missing base, not a repo, …) so callers can distinguish
// "count is genuinely 0" from "count could not be determined".
function gitRevListCount(projectDir: string, baseSha: string): number {
  const out = gitLog(projectDir, ["rev-list", "--count", `${baseSha}..HEAD`]);
  if (!out) return NaN;
  const n = parseInt(out, 10);
  return isNaN(n) ? NaN : n;
}

export const HANDLER_META = {
  name: "committer-single-commit-per-cycle",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    if (parseAgentType() !== "committer") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("committer-single-commit-per-cycle", `cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match or
    // counter increment.
    if (isCodegenLogWrite(command)) return;

    if (!/\bgit\s+commit(?:[\s;&|]|$)/.test(command)) return;

    const projectDir =
      process.env["CLAUDE_PROJECT_DIR"] ??
      process.env["CWD"] ??
      process.cwd();

    const baseSha = process.env["CODEGEN_CYCLE_BASE_SHA"] ?? "";

    if (/--amend/.test(command)) {
      if (baseSha) {
        const cycleCommitCount = gitRevListCount(projectDir, baseSha);
        if (!isNaN(cycleCommitCount) && cycleCommitCount === 0) {
          return deny(
            `BLOCKED by committer-single-commit-per-cycle: --amend has nothing to amend within this build cycle (HEAD == cycle base ${baseSha}). No commit from this cycle exists yet — that would rewrite a commit from BEFORE this build cycle, which is immutable to this one. To allow (emergency only): set COMMITTER_ALLOW_MULTI=1`,
          );
        }
      }
      debugLog(
        "committer-single-commit-per-cycle",
        "allow: --amend present (a cycle commit exists or base sha unset)",
      );
      return;
    }

    if (process.env["COMMITTER_ALLOW_MULTI"] === "1") {
      debugLog(
        "committer-single-commit-per-cycle",
        "allow: COMMITTER_ALLOW_MULTI=1",
      );
      return;
    }

    if (!baseSha) {
      debugLog(
        "committer-single-commit-per-cycle",
        "allow: CODEGEN_CYCLE_BASE_SHA unset",
      );
      return;
    }

    const sessionCount = gitRevListCount(projectDir, baseSha);
    if (isNaN(sessionCount) || sessionCount === 0) {
      debugLog(
        "committer-single-commit-per-cycle",
        "allow: no session commits yet",
      );
      return;
    }

    return deny(
      `BLOCKED by committer-single-commit-per-cycle: a commit was already made in this build cycle (${sessionCount} session commit(s) found since cycle base ${baseSha}).\nOnly one commit per build cycle is allowed.\nTo amend the existing commit use: git commit --amend\nTo allow multiple commits (emergency only): set COMMITTER_ALLOW_MULTI=1`,
    );
  });
}
