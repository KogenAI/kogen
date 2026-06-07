/**
 * committer-tool-guard.ts — Pi enforcement: limit committer tool surface.
 *
 * Mirrors: harnesses/claude/hooks/committer-tool-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash|write|edit
 *
 * Bash branch: deny build/test/package-manager commands (denylist).
 *   Accepted risk: a build tool not in the denylist slips through.
 *   True default-deny Bash allowlist requires compiler support tracked in
 *   pitch reusable-role-scoped-guards.md — out of scope here.
 *
 * Write|Edit branch: allow only canonical session-log paths, deny all else.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  deny,
  parseAgentType,
  debugLog,
  repoRelative,
} from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "committer-tool-guard",
  event: "tool_call",
  matcher: "bash|write|edit",
} as const;

/**
 * Build-tool denylist regex (word-boundary anchored).
 * Accepted gap: new/unlisted build tools pass through.
 */
const BUILD_TOOL_DENYLIST =
  /(^|[^a-zA-Z0-9_])(make|mix|npm|npx|node|yarn|pnpm|pytest|cargo|bundle)([^a-zA-Z0-9_]|$)/;

/**
 * Canonical session-log allowlist regex.
 * SCHEMA: session-log.md
 */
const SESSION_LOG_REGEX =
  /codegen\/logging\/[0-9]{8}_[0-9]{6}(_[a-z0-9-]+)?_(session|step[0-9]+_[a-z0-9-]+)\.md$/;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (
      event.toolName !== "bash" &&
      event.toolName !== "write" &&
      event.toolName !== "edit"
    )
      return;

    if (parseAgentType() !== "committer") return;

    debugLog("committer-tool-guard", `tool=${event.toolName} agent=committer`);

    if (event.toolName === "bash") {
      const command: string =
        (event.input as { command?: string }).command ?? "";
      if (BUILD_TOOL_DENYLIST.test(command)) {
        return deny(
          "BLOCKED by committer-tool-guard: build/test tool forbidden for committer. Only git read/write commands allowed. (Denylist gap accepted per pitch reusable-role-scoped-guards.md)",
        );
      }
      return;
    }

    // write or edit — allowlist only canonical session log paths
    const filePath: string =
      (event.input as { file_path?: string }).file_path ?? "";
    const rel = repoRelative(filePath);
    if (SESSION_LOG_REGEX.test(rel)) {
      return;
    }

    return deny(
      `BLOCKED by committer-tool-guard: committer may only write to canonical session logs, not: ${filePath}`,
    );
  });
}
