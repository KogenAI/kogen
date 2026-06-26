/**
 * orchestrator-read-discipline.ts — Pi enforcement: restrict orchestrator read/Bash access.
 *
 * Mirrors: harnesses/claude/hooks/orchestrator-read-discipline.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: read|bash
 *
 * Blocks the orchestrator from:
 *   1. Reading arbitrary codebase files (read tool — path allowlist enforced)
 *   2. Investigating via Bash with exploration verbs: find, grep, rg, ls, tree, cat
 *      (denial anchored on LEADING token only so git/make/date/cp pass through)
 *
 * Bypass ladder (same order as claude hook):
 *   1. Role debug|shape (PI_ROLE) → allow
 *   2. Not outer session (AGENT_TYPE non-empty = subagent) → allow
 *   3. Orchestrator (AGENT_TYPE empty) → apply gates
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, isOuterSession, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "orchestrator-read-discipline",
  event: "tool_call",
  matcher: "read|bash",
} as const;

/** Resolve the active Pi role from PI_ROLE env var. */
function resolveRole(): string {
  return process.env["PI_ROLE"] ?? "";
}

/**
 * Read path allowlist — mirrors claude hook allowlist checks.
 * Returns true if the file path is permitted for orchestrator Read.
 */
function isAllowedReadPath(filePath: string): boolean {
  if (!filePath) return true; // empty path — let tool handle it

  // Normalise: strip leading slash-prefixed cwd if present (absolute → relative).
  // We operate on the relative path form for pattern matching.
  let rel = filePath;

  // Allowlist 1: codegen/logging/ (session logs)
  if (/^codegen\/logging\//.test(rel)) return true;

  // Allowlist 2: orchestrator rule files
  if (
    /^codegen\/rules\/(roles\/orchestrator\.md|shared\/git-readonly\.md|stacks\/phoenix\/(_core|orchestrator)\.md|_core\/[^/]+\.md|INDEX\.md|STYLE_GUIDE\.md)$/.test(
      rel,
    )
  )
    return true;

  // Allowlist 2b: build-runtime rules for user-app orchestrators
  if (/^codegen\/rules\/build-runtime\/[^/]+\.md$/.test(rel)) return true;

  // Allowlist 3: codegen/*.md (top-level design docs only — no subdirs)
  // Exclude PROJECT_CONTEXT.md — planner reads it, orchestrator must not.
  const topLevelMatch = rel.match(/^codegen\/([^/]+\.md)$/);
  if (topLevelMatch) {
    const basename = topLevelMatch[1];
    if (basename !== "PROJECT_CONTEXT.md") return true;
  }

  // Allowlist 4: codegen/pitches/ (draft/ready/shipped)
  if (/^codegen\/pitches\//.test(rel)) return true;

  return false;
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "read" && event.toolName !== "bash") return;

    // Bypass 1: role debug|shape
    const role = resolveRole();
    if (role === "debug" || role === "shape") return;

    // Bypass 2: subagent (AGENT_TYPE non-empty = not orchestrator)
    if (!isOuterSession()) return;

    debugLog(
      "orchestrator-read-discipline",
      `tool=${event.toolName} role=${role}`,
    );

    // Branch on tool name.
    if (event.toolName === "bash") {
      const command: string =
        (event.input as { command?: string }).command ?? "";
      if (/^\s*(find|grep|rg|ls|tree|cat)\b/.test(command)) {
        // Extract leading verb for deny message.
        const verbMatch = command.match(/^\s*(find|grep|rg|ls|tree|cat)\b/);
        const verb = verbMatch ? verbMatch[1] : "exploration-verb";
        return deny(
          `Orchestrator cannot investigate via Bash (\`${verb}\`). Delegate to the planner subagent (planner-phoenix / planner-static).\nExample: delegate to planner with 'Find X in lib/...' — planner reads/greps codebase, returns 100-token answer instead of flooding orchestrator context.`,
        );
      }
      return; // allowed Bash (git/make/date/cp/etc.)
    }

    // Read tool — apply path allowlist.
    if (event.toolName === "read") {
      const filePath: string =
        (event.input as { path?: string; file_path?: string }).path ??
        (event.input as { path?: string; file_path?: string }).file_path ??
        "";

      if (isAllowedReadPath(filePath)) return;

      return deny(
        `Orchestrator cannot read ${filePath}. Delegate to the planner subagent (planner-phoenix / planner-static).\nExample: delegate to planner with 'Find X in lib/...' — planner reads codebase, returns 100-token answer instead of flooding orchestrator context.`,
      );
    }
  });
}
