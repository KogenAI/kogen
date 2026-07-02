/**
 * reviewer-bash-allowlist.ts — Pi enforcement: reviewer may only run codegen-log and safe read-only shell utilities (allowlist).
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
  name: "reviewer-bash-allowlist",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("reviewer-bash-allowlist", `cmd=${command}`);

    const agentType = process.env["AGENT_TYPE"] ?? "";
    if (!(agentType === "reviewer-phoenix" || agentType === "reviewer-static")) return;

    if (/(^|\s|\/)codegen-log\b|^\s*(cd\s+\S+\s+&&\s+)?(git\s+(-C\s+\S+\s+)?(diff|status|log|show)\b|echo\b|wc\b|cat\b|ls\b|true\b|:)/.test(command)) {
      return;
    }

    return deny(
      "BLOCKED by reviewer-bash-allowlist: only codegen-log and safe read-only shell utilities (git diff/status/log/show, echo, wc, cat, ls, true, :) allowed for reviewer",
    );
  });
}
