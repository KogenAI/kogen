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
import { deny, debugLog, splitCommandSegments } from "../lib/hook-helpers";

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

    // Allowlist: split command into unquoted-chained segments; EVERY segment
    // must match the allowlist. Prevents an allowed prefix chained via
    // && / ; / | / & to a forbidden command from bypassing the gate.
    const segs = splitCommandSegments(command);
    if (segs === null) {
      return deny("BLOCKED by reviewer-bash-allowlist: only codegen-log and safe read-only shell utilities (git diff/status/log/show, echo, wc, cat, ls, true, :) allowed for reviewer");
    }
    for (const seg of segs) {
      const trimmed = seg.trim();
      if (trimmed === "") continue;
      if (!/^\s*(codegen-log\b|git\s+(-C\s+\S+\s+)?(diff|status|log|show)\b|printf\b|echo\b|wc\b|cat\b|ls\b|true\b|:)/.test(trimmed)) {
        return deny("BLOCKED by reviewer-bash-allowlist: only codegen-log and safe read-only shell utilities (git diff/status/log/show, echo, wc, cat, ls, true, :) allowed for reviewer");
      }
    }
    return;
  });
}
