/**
 * committer-single-commit-per-cycle.ts — Pi enforcement: deny a second non-amend
 * git commit from the committer agent within the same build cycle.
 *
 * Mirrors: harnesses/claude/hooks/committer-single-commit-per-cycle.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * Counts commits made after CODEGEN_BUILD_START_TS; if ≥1 exists and the
 * incoming command is not --amend, the command is denied.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";
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

    if (!/\bgit\s+commit\b/.test(command)) return;

    const projectDir =
      process.env["CLAUDE_PROJECT_DIR"] ??
      process.env["CWD"] ??
      process.cwd();

    if (/--amend/.test(command)) {
      const buildStartTs = process.env["CODEGEN_BUILD_START_TS"] ?? "";
      if (buildStartTs) {
        const buildStartNum = parseInt(buildStartTs, 10);
        const headCtStr = gitLog(projectDir, ["log", "-1", "--format=%ct"]);
        const headCt = headCtStr ? parseInt(headCtStr, 10) : NaN;
        if (!isNaN(headCt) && !isNaN(buildStartNum) && headCt < buildStartNum) {
          return deny(
            `BLOCKED by committer-single-commit-per-cycle: --amend would rewrite a commit from BEFORE this build cycle (HEAD commit time ${headCt} < cycle start ${buildStartNum}). That commit belongs to a prior cycle and is immutable to this one. To allow (emergency only): set COMMITTER_ALLOW_MULTI=1`,
          );
        }
      }
      debugLog(
        "committer-single-commit-per-cycle",
        "allow: --amend present (HEAD time ok or start ts unset)",
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

    const buildStartTs = process.env["CODEGEN_BUILD_START_TS"] ?? "";
    if (!buildStartTs) {
      debugLog(
        "committer-single-commit-per-cycle",
        "allow: CODEGEN_BUILD_START_TS unset",
      );
      return;
    }
    const buildStartNum = parseInt(buildStartTs, 10);

    // Collect session commits: SHAs committed strictly after build start timestamp
    const logOutput = gitLog(projectDir, ["log", "--format=%H %ct"]);
    if (!logOutput) {
      debugLog(
        "committer-single-commit-per-cycle",
        "allow: no git log output",
      );
      return;
    }

    const sessionCommits: string[] = [];
    for (const line of logOutput.split("\n")) {
      const parts = line.trim().split(" ");
      if (parts.length < 2) continue;
      const [sha, ct] = parts;
      const commitTs = parseInt(ct, 10);
      if (!isNaN(commitTs) && commitTs > buildStartNum) {
        sessionCommits.push(sha);
      }
    }

    if (sessionCommits.length === 0) {
      debugLog(
        "committer-single-commit-per-cycle",
        "allow: no session commits yet",
      );
      return;
    }

    return deny(
      `BLOCKED by committer-single-commit-per-cycle: a commit was already made in this build cycle (${sessionCommits.length} session commit(s) found).\nOnly one commit per build cycle is allowed.\nTo amend the existing commit use: git commit --amend\nTo allow multiple commits (emergency only): set COMMITTER_ALLOW_MULTI=1`,
    );
  });
}
