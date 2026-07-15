/**
 * committer-no-revert-prior-commit.ts — Pi enforcement: block commits that silently
 * revert prior session commits.
 *
 * Mirrors: harnesses/claude/hooks/committer-no-revert-prior-commit.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * Note: This hook shells out to git for content comparison. Session-commit
 * discovery uses CODEGEN_CYCLE_BASE_SHA — the SHA captured ONCE at cycle
 * start, before any role ran (identical across every role's env). This also
 * catches a commit made by an EARLIER role in the same cycle, which a
 * per-role timestamp window would miss.
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

function gitBlob(projectDir: string, args: string[]): string | null {
  try {
    return execFileSync("git", ["-C", projectDir, ...args], {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch {
    return null;
  }
}

export const HANDLER_META = {
  name: "committer-no-revert-prior-commit",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    if (parseAgentType() !== "committer") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("committer-no-revert-prior-commit", `cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match or
    // counter increment.
    if (isCodegenLogWrite(command)) return;

    if (!/\bgit\s+commit(?:[\s;&|]|$)/.test(command)) return;

    // Operator escape hatch
    if (process.env["COMMITTER_ALLOW_REVERT"] === "1") {
      debugLog(
        "committer-no-revert-prior-commit",
        "allow: COMMITTER_ALLOW_REVERT=1",
      );
      return;
    }

    const baseSha = process.env["CODEGEN_CYCLE_BASE_SHA"] ?? "";
    if (!baseSha) {
      debugLog(
        "committer-no-revert-prior-commit",
        "allow: CODEGEN_CYCLE_BASE_SHA unset",
      );
      return;
    }

    const projectDir =
      process.env["CLAUDE_PROJECT_DIR"] ??
      process.env["CWD"] ??
      process.cwd();

    // Collect session commits: SHAs reachable from HEAD but not from the
    // cycle-stable base (any role's commit this cycle, not just the
    // committer's).
    const logOutput = gitLog(projectDir, ["rev-list", `${baseSha}..HEAD`]);
    if (!logOutput) {
      debugLog(
        "committer-no-revert-prior-commit",
        "allow: no session commits yet",
      );
      return;
    }

    const sessionCommits = logOutput.split("\n").filter((s) => s.trim());

    if (sessionCommits.length === 0) {
      debugLog(
        "committer-no-revert-prior-commit",
        "allow: no session commits yet",
      );
      return;
    }

    // Get staged file list
    const stagedOutput = gitLog(projectDir, [
      "diff",
      "--cached",
      "--name-only",
    ]);
    if (!stagedOutput) {
      debugLog(
        "committer-no-revert-prior-commit",
        "allow: no staged files",
      );
      return;
    }
    const stagedFiles = stagedOutput.split("\n").filter((f) => f.trim());

    const backwardRollFiles: string[] = [];

    for (const stagedFile of stagedFiles) {
      // Get staged (index) content — null means file not in index (e.g. deleted)
      const stagedContent = gitBlob(projectDir, ["show", `:${stagedFile}`]);
      if (stagedContent === null) continue;

      for (const sessionSha of sessionCommits) {
        // Check if this session commit touched the file
        const changedInCommit = gitLog(projectDir, [
          "diff",
          "--name-only",
          `${sessionSha}^`,
          sessionSha,
          "--",
          stagedFile,
        ]);
        if (!changedInCommit) continue;

        // Get parent state — null means file not present in parent (introduced fresh by that commit)
        const parentContent = gitBlob(projectDir, [
          "show",
          `${sessionSha}^:${stagedFile}`,
        ]);
        // Skip files not present in parent (introduced fresh by that commit)
        if (parentContent === null) continue;

        // Compare byte-for-byte
        if (stagedContent === parentContent) {
          backwardRollFiles.push(
            `${stagedFile} (reverts ${sessionSha})`,
          );
          break;
        }
      }
    }

    if (backwardRollFiles.length > 0) {
      const fileList = backwardRollFiles.map((f) => `  ${f}`).join("\n");
      return deny(
        `BLOCKED by committer-no-revert-prior-commit: staged content silently reverts work from a prior session commit.\nFiles that would roll back:\n${fileList}\nThis is a backward roll — the staged version is byte-identical to the state BEFORE a session commit advanced it.\nIf this is intentional, set COMMITTER_ALLOW_REVERT=1 and retry.`,
      );
    }

    debugLog(
      "committer-no-revert-prior-commit",
      "allow: no backward rolls detected",
    );
  });
}
