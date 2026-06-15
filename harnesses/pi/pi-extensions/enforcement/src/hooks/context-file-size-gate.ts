/**
 * context-file-size-gate.ts — Pi enforcement: block git commits when any staged
 * context/*.md blob exceeds the 40,960-byte (40k) advisory cap.
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
    if (!/\bgit\s+commit\b/.test(command)) return;
    debugLog("context-file-size-gate", `cmd=${command}`);
    try {
      const statusLines = execSync("git diff --cached --name-status", {
        encoding: "utf8",
      })
        .split("\n")
        .filter(Boolean);
      const staged = statusLines
        .filter((l) => /^[AM]\s+context\/[^/]+\.md$/.test(l))
        .map((l) => l.split(/\s+/)[1]);
      if (staged.length === 0) return;
      const over: string[] = [];
      for (const fpath of staged) {
        const blob = execSync(`git show :${JSON.stringify(fpath)}`, {
          encoding: "buffer",
        });
        const bytes = Buffer.byteLength(blob);
        if (bytes > CAP) {
          over.push(
            `context-file-size-gate: ${fpath} is ${bytes} bytes, over the ${CAP}-byte (40k) cap. Compress it or split it.`,
          );
        }
      }
      if (over.length > 0) return deny(over.join("\n"));
    } catch {
      // Not in a git repo / blob unreadable — pass through.
    }
  });
}
