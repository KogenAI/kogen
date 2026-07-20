/**
 * prompt-budget-writer-only.ts — Pi enforcement: templates/generator/prompt-budgets.txt
 * has exactly one legitimate writer — an operator running
 * `prompt_size_budget.py --write` in a terminal. Denies raw write/edit on the
 * file, the --write flag itself, and raw bash write-vocab
 * (redirect/tee/in-place-stream-edit/move-into) into that path, for every
 * agent role.
 *
 * Mirrors: harnesses/claude/hooks/prompt-budget-writer-only.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash|write|edit (Pi has no MultiEdit)
 *
 * Bypasses debug/shape/ops roles. Fails open on all other tools.
 *
 * HANDLER_META is registered from shared/enforcement/registry.yaml
 * (kind: registration) — the header is generated, this body is hand-authored.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, isCodegenLogWrite } from "../lib/hook-helpers";
import { isWaived } from "./_waiver";

export const HANDLER_META = {
  name: "prompt-budget-writer-only",
  event: "tool_call",
  matcher: "bash|write|edit",
} as const;

const BUDGET_PATH_RE = /templates\/generator\/prompt-budgets\.txt$/;
const BUDGET_PATH_ANYWHERE_RE = /templates\/generator\/prompt-budgets\.txt/;

const BASH_WRITE_INTO_BUDGET_RE =
  /(>{1,2}\s*[^\s]*templates\/generator\/prompt-budgets\.txt|\|\s*tee\b.*templates\/generator\/prompt-budgets\.txt|\bsed\b[^|]*-i[^|]*templates\/generator\/prompt-budgets\.txt|\b(mv|cp)\b[^|]*templates\/generator\/prompt-budgets\.txt)/;

const DENY_MSG =
  "BLOCKED by prompt-budget-writer-only: this file is operator-owned — raising a prompt budget is denied for every agent role. This file is full: shrink your addition, or evict the lowest-value content and name what you evicted in your diff. The cap is not the writer's to move.";

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    // Investigative-mode bypass (sibling-guard convention).
    const role = process.env["CLAUDE_ROLE"] || process.env["PI_ROLE"] || "";
    if (role === "debug" || role === "shape" || role === "ops") return;

    if (event.toolName === "write" || event.toolName === "edit") {
      const filePath: string =
        (event.input as { path?: string; file_path?: string }).path ??
        (event.input as { path?: string; file_path?: string }).file_path ??
        "";
      if (!filePath) return;

      debugLog("prompt-budget-writer-only", `tool=${event.toolName} file=${filePath}`);

      if (BUDGET_PATH_RE.test(filePath)) {
        if (isWaived("prompt-budget-writer-only")) return;
        return deny(DENY_MSG);
      }
      return;
    }

    if (event.toolName === "bash") {
      const command: string =
        (event.input as { command?: string }).command ?? "";
      debugLog("prompt-budget-writer-only", `cmd=${command}`);

      // A codegen-log write narrates gated phrases in its heredoc/piped body
      // (e.g. a retrospective mentioning "prompt_size_budget.py --write" as
      // something that was FIXED); it is never the gated action itself.
      // Bypass before any phrase match, mirroring session-log-writer-only.ts.
      if (isCodegenLogWrite(command)) return;

      // Deny the --write flag itself, wherever invoked.
      if (/prompt_size_budget\.py.*--write/.test(command)) {
        if (isWaived("prompt-budget-writer-only")) return;
        return deny(DENY_MSG);
      }

      // Deny Bash write-vocab targeting the budget file directly.
      if (
        BUDGET_PATH_ANYWHERE_RE.test(command) &&
        BASH_WRITE_INTO_BUDGET_RE.test(command)
      ) {
        if (isWaived("prompt-budget-writer-only")) return;
        return deny(DENY_MSG);
      }
      return;
    }
  });
}
