/**
 * context-curator-guard.ts — Pi enforcement: restrict context-curator writes to
 * allowed write surface only.
 *
 * Mirrors: harnesses/claude/hooks/context-curator-guard.sh
 * Event: tool_call
 * Matcher: write|edit
 *
 * Logic:
 *   If AGENT_TYPE === "context-curator" AND file_path is outside:
 *     - context/**
 *     - codegen/rules/**
 *     - codegen/logging/**
 *   → deny with explanation.
 *
 * Fail-open: if file_path is empty → allow.
 * All other agent types: allow unconditionally.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, repoRelative } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "context-curator-guard",
  event: "tool_call",
  matcher: "write|edit",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (!(event.toolName === "write" || event.toolName === "edit")) return;

    const agentType = process.env["AGENT_TYPE"] ?? "";
    if (agentType !== "context-curator") return;

    const filePath: string =
      (event.input as { file_path?: string }).file_path ?? "";

    debugLog("context-curator-guard", `file=${filePath}`);

    if (!filePath) return;

    const rel = repoRelative(filePath);

    // Allowed: context/**
    if (/(^|\/)context\//.test(rel)) return;

    // Allowed: codegen/rules/**
    if (/(^|\/)codegen\/rules(\/|$)/.test(rel)) return;

    // Allowed: codegen/logging/**
    if (/(^|\/)codegen\/logging\//.test(rel)) return;

    return deny(
      `BLOCKED by context-curator-guard: ${filePath} is outside the curator's allowed write surface. Curator may only write to: context/**, codegen/rules/**, codegen/logging/**.`,
    );
  });
}
