/**
 * no-cat-pipe.ts — Pi enforcement: deny `cat FILE | head|tail|grep|less|more`.
 *
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
 * Edit registry.yaml and run `make install` to regenerate.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, isCodegenLogWrite } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "no-cat-pipe",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const _role = process.env["CLAUDE_ROLE"] || process.env["PI_ROLE"] || "";
    if (["ops"].includes(_role)) return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("no-cat-pipe", `cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match or
    // counter increment.
    if (isCodegenLogWrite(command)) return;

    if (/cat\s+[^|]*\|\s*(head|tail|grep|less|more)\b/.test(command)) {
      return deny(
        "Use Read tool with offset/limit instead of `cat | head/tail`. Use Grep tool instead of `cat | grep`. Truncation hides relevant lines.",
      );
    }
  });
}
