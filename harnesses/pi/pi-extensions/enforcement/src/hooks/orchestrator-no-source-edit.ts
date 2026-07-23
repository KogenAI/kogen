/**
 * orchestrator-no-source-edit.ts — Pi enforcement: block orchestrator/subagent
 * source edits outside the role's write boundary.
 *
 * Mirrors: harnesses/claude/hooks/orchestrator-no-source-edit.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: write|edit|multiEdit|notebookEdit (any file-bearing write tool)
 *
 * Role dispatch (PI_ROLE via resolveRole(), same precedence as _role.ts):
 *   ops       → full write surface, no restriction
 *   babysit   → full write surface, no restriction
 *   experiment→ full write surface — native worktree isolation IS the
 *               boundary, not a path restriction
 *   debug|shape → writes scoped to codegen/pitches/ only (applies to
 *               subagents too — the role boundary, not an actor boundary)
 *   (no role) → subagents (AGENT_TYPE set) pass through; plain orchestrator
 *               limited to codegen/logging/, codegen/pitches/, /tmp/
 *
 * Fail-closed: matcher is write-only tools; an empty path is anomalous, not
 * a legitimate skip — denied in every role branch that reaches the check.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, repoRelative, debugLog } from "../lib/hook-helpers";
import { resolveRole } from "./_role";

export const HANDLER_META = {
  name: "orchestrator-no-source-edit",
  event: "tool_call",
  matcher: "write|edit|multiEdit|notebookEdit",
} as const;

const FILE_TOOLS = new Set(["write", "edit", "multiEdit", "notebookEdit"]);

function filePathOf(input: unknown): string {
  const rec = input as { path?: string; file_path?: string };
  return rec.path ?? rec.file_path ?? "";
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (!FILE_TOOLS.has(event.toolName)) return;

    const role = resolveRole();
    const filePath = filePathOf(event.input);
    const relPath = repoRelative(filePath);

    debugLog(
      "orchestrator-no-source-edit",
      `tool=${event.toolName} role=${role} file=${filePath}`,
    );

    // Ops mode — full write surface, no restriction.
    if (role === "ops") return;

    // Babysit mode — full write surface (drain supervisor dispatches shape,
    // which writes pitches, and needs the same ops-equivalent posture).
    if (role === "babysit") return;

    // Experiment mode — source-writable. Confinement is the worktree the
    // launcher runs in, NOT a path restriction on this hook.
    if (role === "experiment") return;

    // Debug/shape operators (read-only investigation + pitch authoring).
    // Writes scoped to codegen/pitches/ — applies to subagents too.
    if (role === "debug" || role === "shape") {
      if (!filePath) {
        return deny(
          `BLOCKED by orchestrator-no-source-edit: empty file path in ${role} mode — file-bearing tool with no resolvable path is anomalous; failing closed.`,
        );
      }
      if (/^codegen\/pitches\//.test(relPath)) return;
      return deny(
        `BLOCKED by orchestrator-no-source-edit: ${role} mode may only write to codegen/pitches/ — got ${filePath}`,
      );
    }

    // Subagents under no role (standard build spawns) pass through.
    if (process.env["AGENT_TYPE"]) return;

    // Plain orchestrator (no role): writes allowed only under
    // codegen/logging/, codegen/pitches/, and absolute /tmp/.
    if (!filePath) {
      return deny(
        "BLOCKED by orchestrator-no-source-edit: empty file path for orchestrator — file-bearing tool with no resolvable path is anomalous; failing closed.",
      );
    }
    if (/^codegen\/logging\//.test(relPath)) return;
    if (/^(\/private)?\/tmp\//.test(filePath)) return;
    if (/^codegen\/pitches\//.test(relPath)) return;

    return deny(
      `BLOCKED by orchestrator-no-source-edit: ${role || "orchestrator"} may only write to codegen/logging/, codegen/pitches/, or absolute /tmp/ (${filePath}). Delegate source edits to developer-phoenix-backend / developer-phoenix-frontend / developer-static.`,
    );
  });
}
