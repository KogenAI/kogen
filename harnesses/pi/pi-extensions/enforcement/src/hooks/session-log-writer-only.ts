/**
 * session-log-writer-only.ts — Pi enforcement: codegen-log is the SOLE
 * writer of session logs. Denies raw write/edit on codegen/logging/*.md
 * and raw bash writes (redirect/tee/in-place-stream-edit/move-into) into
 * that path.
 *
 * Mirrors: harnesses/claude/hooks/session-log-writer-only.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash|write|edit (Pi has no MultiEdit)
 *
 * Bypasses debug/shape/ops roles. Fails open on all other tools.
 *
 * HANDLER_META is registered from shared/enforcement/registry.yaml
 * (kind: registration) — the header is generated, this body is hand-authored.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "session-log-writer-only",
  event: "tool_call",
  matcher: "bash|write|edit",
} as const;

const BASH_WRITE_INTO_LOG_RE =
  /(>{1,2}\s*[^\s]*codegen\/logging\/|\|\s*tee\b.*codegen\/logging\/|\bsed\b[^|]*-i[^|]*codegen\/logging\/|\b(mv|cp)\b[^|]*codegen\/logging\/)/;

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

      debugLog("session-log-writer-only", `tool=${event.toolName} file=${filePath}`);

      if (filePath.includes("codegen/logging/") && filePath.endsWith(".md")) {
        return deny(
          `BLOCKED by session-log-writer-only: raw ${event.toolName} on session logs is denied — write via codegen-log (init / section --body @- / section --role <role> / append --role <role>).`,
        );
      }
      return;
    }

    if (event.toolName === "bash") {
      const command: string =
        (event.input as { command?: string }).command ?? "";
      debugLog("session-log-writer-only", `cmd=${command}`);

      // Allow any command that invokes codegen-log — the sole legitimate writer.
      if (/(^|[\s/])codegen-log\b/.test(command)) return;

      // Deny raw writes into codegen/logging/*.md that don't go through codegen-log.
      if (
        /codegen\/logging\/[^\s]*\.md/.test(command) &&
        BASH_WRITE_INTO_LOG_RE.test(command)
      ) {
        return deny(
          "BLOCKED by session-log-writer-only: raw Bash write into a session log is denied — write via codegen-log (init / section --body @- / section --role <role> / append --role <role>).",
        );
      }
      return;
    }
  });
}
