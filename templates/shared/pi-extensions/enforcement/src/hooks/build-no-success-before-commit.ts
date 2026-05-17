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

    const command: string =
      (event.input as { command?: string }).command ?? "";

    if (!command.includes("BUILD_RESULT:")) return;

    const buildStartTs = process.env["COMBOBULATE_BUILD_START_TS"];
    if (!buildStartTs) {
      debugLog("build-no-success-before-commit", "allow: COMBOBULATE_BUILD_START_TS unset");
      return;
    }

    const startTs = parseInt(buildStartTs, 10);
    debugLog("build-no-success-before-commit", `build_start_ts=${startTs}`);

    try {
      const lastCommitTs = execSync("git log -1 --format=%ct", {
        encoding: "utf8",
      }).trim();

      if (lastCommitTs && parseInt(lastCommitTs, 10) > startTs) {
        return;
      }
    } catch {
      // No commits or not in a git repo
    }

    return deny(
      "BLOCKED by build-no-success-before-commit: cannot signal BUILD_RESULT: before a commit has been made. Commit your changes first."
    );
  });
}
