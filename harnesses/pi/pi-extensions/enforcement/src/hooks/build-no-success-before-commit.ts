/**
 * build-no-success-before-commit.ts — Pi enforcement: block BUILD_RESULT: before
 * a commit has been made.
 *
 * Mirrors: templates/shared/hooks/build-no-success-before-commit.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import { execSync } from "node:child_process";

export const HANDLER_META = {
  name: "build-no-success-before-commit",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string = (event.input as { command?: string }).command ?? "";

    if (!command.includes("BUILD_RESULT:")) return;

    const buildStartTs = process.env["COMBOBULATE_BUILD_START_TS"];
    if (!buildStartTs) {
      debugLog(
        "build-no-success-before-commit",
        "allow: COMBOBULATE_BUILD_START_TS unset",
      );
      return;
    }

    const startTs = parseInt(buildStartTs, 10);
    debugLog("build-no-success-before-commit", `build_start_ts=${startTs}`);

    let commitFound = false;
    try {
      const lastCommitTs = execSync("git log -1 --format=%ct", {
        encoding: "utf8",
      }).trim();

      if (lastCommitTs && parseInt(lastCommitTs, 10) > startTs) {
        commitFound = true;
      }
    } catch {
      // No commits or not in a git repo
    }

    if (!commitFound) {
      return deny(
        "BLOCKED by build-no-success-before-commit: cannot signal BUILD_RESULT: before a commit has been made. Commit your changes first.",
      );
    }

    // Require a clean working tree — no uncommitted or untracked files.
    try {
      const porcelain = execSync("git status --porcelain", {
        encoding: "utf8",
      }).trim();

      if (porcelain) {
        const lines = porcelain.split("\n").filter(Boolean);
        const count = lines.length;
        const fileList = lines.map((l) => l.replace(/^\S+\s+/, "")).join(", ");
        return deny(
          `BLOCKED by build-no-success-before-commit: working tree not clean — ${count} file(s) uncommitted: ${fileList}. Commit all cycle output in one commit before signaling SHIPPED.`,
        );
      }
    } catch {
      // Not in a git repo or git unavailable — skip clean-tree check
    }

    return;
  });
}
