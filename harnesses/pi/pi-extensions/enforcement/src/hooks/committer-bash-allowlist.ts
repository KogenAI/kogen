/**
 * committer-bash-allowlist.ts — Pi enforcement: committer may only run git commands and safe shell utilities (allowlist).
 *
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
 * Edit registry.yaml and run `make install` to regenerate.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "committer-bash-allowlist",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("committer-bash-allowlist", `cmd=${command}`);

    const agentType = process.env["AGENT_TYPE"] ?? "";
    if (!(agentType === "committer")) return;

    if (/^\s*(cd\s+\S+\s+&&\s+)?(git\s+(-C\s+\S+\s+)?(diff|status|log|show|commit|add|rm|mv|tag|checkout|switch|branch|restore|reset)\b|echo\b|wc\b|cat\b|ls\b|true\b|:)/.test(command)) {
      return;
    }

    return deny(
      "BLOCKED by committer-bash-allowlist: only git read/write commands and safe shell utilities allowed for committer",
    );
  });
}
