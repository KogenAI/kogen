/**
 * subagent-allowlist.ts — Pi enforcement: gate subagent spawns from pi-subagents extension.
 *
 * Mirrors: templates/shared/hooks/operator-subagent-allowlist.sh
 * Event: tool_call (pi-subagents registers spawn as a tool_call named "subagent")
 * Matcher: subagent
 *
 * Rules (mirroring operator-subagent-allowlist.sh):
 *   Built-in subagent types {Plan, general-purpose, statusline-setup} — denied always.
 *   Empty subagent_type — denied defensively (fail-closed).
 *   Explore — allowed only under debug/shape/refactor PI_ROLE.
 *   All other project subagents — allowed.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "subagent-allowlist",
  event: "tool_call",
  matcher: "subagent",
} as const;

/** Resolve the active Pi role from PI_ROLE env var. */
function resolveRole(): string {
  return process.env["PI_ROLE"] ?? "";
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "subagent") return;

    const subagentType: string =
      (event.input as { agent?: string; subagent_type?: string }).agent ??
      (event.input as { agent?: string; subagent_type?: string })
        .subagent_type ??
      "";

    const role = resolveRole();

    debugLog(
      "subagent-allowlist",
      `role=${role} subagent_type=${subagentType}`,
    );

    // Built-in subagent types — denied in all launcher modes.
    if (
      subagentType === "Plan" ||
      subagentType === "general-purpose" ||
      subagentType === "statusline-setup"
    ) {
      return deny(
        `BLOCKED by subagent-allowlist: built-in subagent ${subagentType} is denied in all launcher modes.`,
      );
    }

    // Empty subagent_type — deny defensively (fail-closed).
    if (!subagentType) {
      return deny(
        `BLOCKED by subagent-allowlist: subagent_type is empty — cannot determine safe subagent. Specify a named project subagent.`,
      );
    }

    // Explore — allowed only under debug/shape/refactor operator roles.
    if (subagentType === "Explore") {
      if (role === "debug" || role === "shape" || role === "refactor") {
        return;
      }
      return deny(
        `BLOCKED by subagent-allowlist: Explore subagent is only available under pi-debug, pi-shape, or pi-refactor launcher modes. Use planner-phoenix / planner-html / etc. instead for investigation within a standard build session.`,
      );
    }

    // Shape/refactor modes are read-only — deny source-editing subagents.
    if (role === "shape" || role === "refactor") {
      if (
        subagentType.startsWith("developer-") ||
        subagentType.startsWith("reviewer-") ||
        subagentType === "committer"
      ) {
        return deny(
          `BLOCKED by subagent-allowlist: shaping modes are read-only — they investigate and write pitches; spawn a builder from build mode instead.`,
        );
      }
    }

    // All other subagent types (project subagents) — allow.
    return;
  });
}
