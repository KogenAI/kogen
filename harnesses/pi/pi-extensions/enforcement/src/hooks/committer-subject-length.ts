/**
 * committer-subject-length.ts — Pi enforcement: block git commits with subjects
 * longer than 50 bytes.
 *
 * Mirrors: templates/shared/hooks/committer-subject-length.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  deny,
  parseAgentType,
  debugLog,
  isCodegenLogWrite,
} from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "committer-subject-length",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    if (parseAgentType() !== "committer") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("committer-subject-length", `cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match or
    // counter increment.
    if (isCodegenLogWrite(command)) return;

    if (!/\bgit\s+commit(?:[\s;&|]|$)/.test(command)) return;

    // Block heredoc form — can't extract subject
    if (/git\s+commit\s+-m\s+"[^"]*\$\(cat\s+<</.test(command)) {
      return deny(
        'BLOCKED by committer-subject-length: heredoc form not supported — use -m "subject" with ≤50B subject line',
      );
    }

    // Extract -m "..." or -m '...' argument
    const mMatch = command.match(/-m\s+(?:"([^"]+)"|'([^']+)')/);
    if (!mMatch) return;

    const msg = mMatch[1] ?? mMatch[2] ?? "";
    const byteLen = Buffer.byteLength(msg, "utf8");

    if (byteLen > 50) {
      return deny(
        `BLOCKED by committer-subject-length: commit subject "${msg}" is ${byteLen} bytes; max 50. Shorten and retry.`,
      );
    }
  });
}
