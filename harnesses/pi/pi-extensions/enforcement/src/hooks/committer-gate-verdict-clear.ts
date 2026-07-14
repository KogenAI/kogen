/**
 * committer-gate-verdict-clear.ts — Pi enforcement: deny a git commit from
 * the committer agent unless codegen/gate-pending/gate-result.json exists
 * and its .verdict field is "clear".
 *
 * Mirrors: harnesses/claude/hooks/committer-gate-verdict-clear.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * The committer's own rule (shared/rules/roles/committer.md) says: read the
 * .verdict field of codegen/gate-pending/gate-result.json; absent or
 * non-clear → do not commit. This hook makes that structural rather than an
 * unenforced instruction. Verdict-only — no freshness/base_sha check here.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  deny,
  parseAgentType,
  debugLog,
  isCodegenLogWrite,
  getGateVerdict,
} from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "committer-gate-verdict-clear",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    if (parseAgentType() !== "committer") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("committer-gate-verdict-clear", `cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match.
    if (isCodegenLogWrite(command)) return;

    if (!/\bgit\s+commit(?:[\s;&|]|$)/.test(command)) return;

    const projectDir =
      process.env["CLAUDE_PROJECT_DIR"] ??
      process.env["CWD"] ??
      process.cwd();

    const verdict = getGateVerdict(projectDir);

    if (verdict !== "clear") {
      return deny(
        `BLOCKED by committer-gate-verdict-clear: gate-result.json verdict is '${verdict || "absent"}' (need 'clear'). Do not commit — the build has not reached a clear gate verdict.`,
      );
    }

    debugLog("committer-gate-verdict-clear", "allow: verdict=clear");
  });
}
