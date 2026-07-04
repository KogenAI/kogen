/**
 * context-file-size-gate.ts — Pi enforcement: block git commits when any staged
 * context/*.md blob exceeds the 40,960-byte (40k) cap. This is a commit-time
 * BACKSTOP — the primary enforcement is curator-context-size-gate.ts, which
 * denies the over-cap write/edit in the context-curator's own turn. The
 * committer cannot Read or edit context/*.md, so this backstop's deny message
 * routes the orchestrator to re-spawn the context-curator, never the committer.
 *
 * Mirrors: harnesses/claude/hooks/context-file-size-gate.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * Reduced-fidelity note: parity is high here (no transcript dependency).
 * execSync runs in process.cwd() — same as context-index-parity.ts.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import { execSync } from "node:child_process";

export const HANDLER_META = {
  name: "context-file-size-gate",
  event: "tool_call",
  matcher: "bash",
} as const;

const CAP = 40960;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    const command: string = (event.input as { command?: string }).command ?? "";
    if (!/(^|[\s;&|])git\s+commit\b/.test(command)) return;
    debugLog("context-file-size-gate", `cmd=${command}`);
    let statusLines: string[];
    try {
      statusLines = execSync("git diff --cached --name-status", {
        encoding: "utf8",
      })
        .split("\n")
        .filter(Boolean);
    } catch {
      // Not in a git repo — pass through.
      return;
    }

    const staged = statusLines
      .filter((l) => /^[AM]\s+context\/[^/]+\.md$/.test(l))
      .map((l) => l.split(/\s+/)[1]);
    if (staged.length === 0) return;

    // Run OUTSIDE the repo-absence catch: a git-show failure here means the
    // blob genuinely could not be read for a staged path, not repo-absence.
    // Deny rather than silently skip size-checking that file.
    const over: string[] = [];
    for (const fpath of staged) {
      let blob: Buffer;
      try {
        blob = execSync(`git show :${JSON.stringify(fpath)}`, {
          encoding: "buffer",
        });
      } catch (e) {
        return deny(
          `context-file-size-gate (backstop): could not read staged blob for ${fpath} via 'git show' (${(e as Error).message}). Cannot verify the 40,960-byte (40k) cap was not exceeded — resolve the git error before committing.`,
        );
      }
      const bytes = Buffer.byteLength(blob);
      if (bytes > CAP) {
        over.push(
          `context-file-size-gate (backstop): staged context file ${fpath} is ${bytes} bytes, over the ${CAP}-byte (40k) cap. The committer cannot Read or edit context/*.md — do NOT trim it here. Orchestrator: re-spawn the context-curator to compress or split ${fpath} under 40960 bytes, then re-run the cycle.`,
        );
      }
    }
    if (over.length > 0) return deny(over.join("\n"));
  });
}
