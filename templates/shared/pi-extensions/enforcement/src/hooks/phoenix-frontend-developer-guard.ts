/**
 * phoenix-frontend-developer-guard.ts — Pi enforcement: restrict frontend
 * developer to frontend paths only.
 *
 * Mirrors: templates/shared/hooks/phoenix-frontend-developer-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: edit, write
 *
 * Blocks edit/write on backend-owned paths so the frontend developer
 * cannot accidentally clobber Ecto schemas, migrations, contexts, services,
 * workers, or other backend-only files.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "phoenix-frontend-developer-guard",
  event: "tool_call",
  matcher: "edit|write",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return;
    if (parseAgentType() !== "developer-phoenix-frontend") return;

    const filePath: string =
      (event.input as { path?: string; file_path?: string }).path ??
      (event.input as { path?: string; file_path?: string }).file_path ??
      "";

    debugLog("phoenix-frontend-developer-guard", `file=${filePath}`);

    if (!filePath) return;

    // priv/repo/migrations/ — always backend
    if (/(^|\/)priv\/repo\/migrations\//.test(filePath)) {
      return deny(
        `BLOCKED by phoenix-frontend-developer-guard: "${filePath}" is a backend migration file. Delegate to developer-phoenix-backend.`
      );
    }

    // lib/*/contexts/, lib/*/services/, lib/*/workers/ — backend subtrees
    if (/(^|\/)lib\/[^/]+\/(contexts|services|workers)\//.test(filePath)) {
      return deny(
        `BLOCKED by phoenix-frontend-developer-guard: "${filePath}" is a backend context/service/worker path. Delegate to developer-phoenix-backend.`
      );
    }

    // lib/<app>_web/ — frontend, allow
    if (/(^|\/)lib\/[^/]+_web(\/|$)/.test(filePath)) {
      return; // frontend, allowed
    }

    // lib/<app>/ (non-_web) — backend
    if (/(^|\/)lib\/[^/]+\//.test(filePath)) {
      return deny(
        `BLOCKED by phoenix-frontend-developer-guard: "${filePath}" is under lib/<app>/ (backend). Delegate to developer-phoenix-backend.`
      );
    }
  });
}
