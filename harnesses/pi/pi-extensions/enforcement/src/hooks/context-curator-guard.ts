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
 *     - PROJECT_CONTEXT.md (§ Domain Context Files rows)
 *   → deny with explanation.
 *
 * Fail-open: if file_path is empty → allow.
 * All other agent types: allow unconditionally.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, repoRelative, resolveRealPath } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "context-curator-guard",
  event: "tool_call",
  matcher: "write|edit",
} as const;

/**
 * warnIfOverCap — projects post-write line count and emits a stderr warning
 * when a rule-file write would exceed the file's COMMITTED budget row in
 * templates/generator/prompt-budgets.txt (the number make prompt-size-budget
 * actually enforces — NOT the STYLE_GUIDE tier caps, which are advisory
 * targets for new files only and disagree with the enforced gate on every
 * pre-existing file already at/over its tier cap).
 * NEVER blocks — always returns undefined (warn-only).
 *
 * Resolution: resolve filePath to its real (symlink-free) path, then walk up
 * parent directories looking for templates/generator/prompt-budgets.txt —
 * that directory is the repo root. Look up the repo-relative key in the
 * budgets file; compare projected lines to that row.
 *
 * Projection formula:
 *   Edit → (on-disk line count) - newlines(old_string) + newlines(new_string)
 *   Write → newlines(content)  [file is fully replaced]
 *
 * Skips silently on: MultiEdit, missing/unparseable payload, unresolvable
 * repo root, no budget row for this file, unreadable budgets file, any I/O
 * error.
 */
function warnIfOverCap(
  filePath: string,
  toolName: string,
  input: Record<string, unknown>,
): void {
  // MultiEdit has no single old/new_string — fail-open.
  if (toolName === "multiedit" || toolName === "MultiEdit") return;

  const realPath = resolveRealPath(filePath);
  if (!realPath) return;

  let root = realPath;
  let budgetsFile = "";
  while (root !== path.dirname(root)) {
    root = path.dirname(root);
    const candidate = path.join(root, "templates", "generator", "prompt-budgets.txt");
    if (fs.existsSync(candidate)) {
      budgetsFile = candidate;
      break;
    }
  }
  if (!budgetsFile) return;

  const key = path.relative(root, realPath);
  let cap = 0;
  try {
    const budgetsContent = fs.readFileSync(budgetsFile, "utf8");
    const row = budgetsContent
      .split("\n")
      .find((line) => line.startsWith(`${key} `));
    if (!row) return;
    const parsed = parseInt(row.slice(key.length + 1).trim(), 10);
    if (Number.isNaN(parsed)) return;
    cap = parsed;
  } catch {
    return; // Unreadable budgets file — fail-open.
  }

  // Count newlines in a string (\n occurrences).
  const countNl = (s: string): number => {
    let n = 0;
    for (let i = 0; i < s.length; i++) if (s[i] === "\n") n++;
    return n;
  };

  let projected = 0;
  try {
    if (toolName === "write") {
      // Write replaces the file entirely — project from content newlines.
      const content = (input["content"] as string | undefined) ?? "";
      projected = countNl(content);
    } else if (toolName === "edit") {
      const newString = (input["new_string"] as string | undefined) ?? "";
      const oldString = (input["old_string"] as string | undefined) ?? "";
      // Both empty → unparseable payload — fail-open.
      if (!newString && !oldString) return;
      let currentLines = 0;
      if (fs.existsSync(filePath)) {
        const onDisk = fs.readFileSync(filePath, "utf8");
        currentLines = countNl(onDisk);
      }
      projected = currentLines - countNl(oldString) + countNl(newString);
    } else {
      return;
    }
  } catch {
    return; // I/O or parse error — fail-open.
  }

  if (projected > cap) {
    process.stderr.write(
      `[pi-enforcement:context-curator-guard] WARNING: ${filePath} — projected ${projected} lines exceeds committed budget ${cap} (templates/generator/prompt-budgets.txt). make prompt-size-budget will fail. Evict or compress an equal amount in this pass — the budget is operator-owned and not yours to raise.\n`,
    );
  }
}

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
    if (/(^|\/)codegen\/rules(\/|$)/.test(rel)) {
      warnIfOverCap(filePath, event.toolName, event.input as Record<string, unknown>);
      return;
    }

    // Allowed: codegen/logging/**
    if (/(^|\/)codegen\/logging\//.test(rel)) return;

    // Allowed: PROJECT_CONTEXT.md § Domain Context Files rows (curator maintains index↔context parity)
    if (/(^|\/)PROJECT_CONTEXT\.md$/.test(rel)) return;

    return deny(
      `BLOCKED by context-curator-guard: ${filePath} is outside the curator's allowed write surface. Curator may only write to: context/**, codegen/rules/**, codegen/logging/**, PROJECT_CONTEXT.md.`,
    );
  });
}
