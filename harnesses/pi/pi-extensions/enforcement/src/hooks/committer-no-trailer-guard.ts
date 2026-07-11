/**
 * committer-no-trailer-guard.ts — Pi enforcement: block git commits without -m flag.
 *
 * Mirrors: templates/shared/hooks/committer-no-trailer-guard.sh
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
  name: "committer-no-trailer-guard",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    if (parseAgentType() !== "committer") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("committer-no-trailer-guard", `cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match or
    // counter increment.
    if (isCodegenLogWrite(command)) return;

    if (!/\bgit\s+commit(?:[\s;&|]|$)/.test(command)) return;

    // Allow if -m flag is present (covers `-m "..."`, `-m'...'`, and the
    // no-space forms `-m"..."`/`-m'...'`)
    if (/-m['"\s]/.test(command)) return;

    // --file or -F forms — denied
    if (/\bgit\s+commit\b.*(-F\s|--file\s)/.test(command)) {
      return deny(
        'BLOCKED by committer-no-trailer-guard: git commit --file/-F not allowed. Use -m "subject" with inline message.',
      );
    }

    // Bare git commit (no -m) — denied
    return deny(
      'BLOCKED by committer-no-trailer-guard: git commit requires -m "subject". Use: git commit -m "subject line"',
    );
  });
}
