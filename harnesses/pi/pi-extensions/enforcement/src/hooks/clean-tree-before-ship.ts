/**
 * clean-tree-before-ship.ts — Pi enforcement: block the pitch ship-mv
 * (mv codegen/pitches/ready/<slug>.md codegen/pitches/shipped/<slug>.md) when
 * the working tree is not clean (orphaned cycle output).
 *
 * Mirrors: harnesses/claude/hooks/clean-tree-before-ship.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import { execSync } from "node:child_process";

export const HANDLER_META = {
  name: "clean-tree-before-ship",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string = (event.input as { command?: string }).command ?? "";

    // Match only the ship mv: requires BOTH ready/ and shipped/ pitch paths.
    if (!command.includes("codegen/pitches/ready/")) return;
    if (!command.includes("codegen/pitches/shipped/")) return;

    debugLog("clean-tree-before-ship", "ship mv detected");

    // Fail-open: not a git repo / git unavailable.
    try {
      execSync("git rev-parse --show-toplevel", { stdio: "ignore" });
    } catch {
      debugLog("clean-tree-before-ship", "allow: not a git repo");
      return;
    }

    try {
      const porcelain = execSync("git status --porcelain", {
        encoding: "utf8",
      }).trim();
      if (porcelain) {
        const lines = porcelain.split("\n").filter(Boolean);
        const count = lines.length;
        const fileList = lines.map((l) => l.replace(/^\S+\s+/, "")).join(", ");
        return deny(
          `BLOCKED by clean-tree-before-ship: working tree not clean — ${count} file(s) uncommitted: ${fileList}. Commit all cycle output before shipping the pitch (mv ready/ → shipped/).`,
        );
      }
    } catch {
      // git unavailable — fail-open
      return;
    }

    return;
  });
}
