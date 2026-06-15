/**
 * curator-learning-committed.ts — Pi enforcement: OBSERVE-ONLY twin.
 *
 * CAPABILITY GAP: Pi has no access to the session log or transcript (no
 * TRANSCRIPT_PATH, no disk scan of codegen/logging/). The full check —
 * resolving the curator section, extracting "Files edited:" paths, and
 * verifying those paths appear in HEAD — requires session-log access that
 * is not available in the Pi runtime. This hook emits a stderr advisory
 * and always allows. Full enforcement lives in the Claude Code twin:
 * harnesses/claude/hooks/curator-learning-committed.sh
 *
 * Mirrors: harnesses/claude/hooks/curator-learning-committed.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const HANDLER_META = {
  name: "curator-learning-committed",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string = (event.input as { command?: string }).command ?? "";

    if (!command.includes("BUILD_RESULT:")) return;

    const buildStartTs = process.env["CODEGEN_BUILD_START_TS"];
    if (!buildStartTs) return;

    // OBSERVE-ONLY: Pi has no session-log/transcript access.
    // Emit advisory to stderr; never block.
    process.stderr.write(
      "[curator-learning-committed] Pi harness: session-log access unavailable; " +
        "curator-learning-committed check skipped (reduced fidelity — no transcript access in Pi)\n",
    );

    // NEVER call block() — this hook is observe-only.
    return;
  });
}
