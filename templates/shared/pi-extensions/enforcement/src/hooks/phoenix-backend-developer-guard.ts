/**
 * phoenix-backend-developer-guard.ts — Pi enforcement: restrict backend
 * developer to backend paths only.
 *
 * Mirrors: templates/shared/hooks/phoenix-backend-developer-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: edit, write
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "phoenix-backend-developer-guard",
  event: "tool_call",
  matcher: "edit|write",
} as const;

// Frontend-owned path patterns
const FRONTEND_PATTERNS = [
  /\/[^/]+_web\//,   // lib/<app>_web/
  /\/assets\//,      // assets/
  /\/priv\/static\//, // priv/static/
  /\.heex$/,         // HEEx templates
  /_html\.ex$/,      // Phoenix HTML modules
];

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return;
    if (parseAgentType() !== "developer-phoenix-backend") return;

    const filePath: string =
      (event.input as { path?: string; file_path?: string }).path ??
      (event.input as { path?: string; file_path?: string }).file_path ??
      "";

    debugLog("phoenix-backend-developer-guard", `file=${filePath}`);

    if (!filePath) return;

    for (const pattern of FRONTEND_PATTERNS) {
      if (pattern.test(filePath)) {
        return deny(
          `BLOCKED by phoenix-backend-developer-guard: path "${filePath}" is frontend-owned. Backend dev must not touch LiveView/HEEx/JS/assets — delegate to developer-phoenix-frontend.`
        );
      }
    }
  });
}
