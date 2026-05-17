/**
 * static-site-ex-guard.ts — Pi enforcement: block static-site devs from
 * editing .ex/.exs files.
 *
 * Mirrors: templates/shared/hooks/static-site-ex-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: write, edit
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "static-site-ex-guard",
  event: "tool_call",
  matcher: "write|edit",
} as const;

const STATIC_DEV_AGENTS = new Set([
  "developer-html",
  "developer-hugo",
  "developer-vite",
]);

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "write" && event.toolName !== "edit") return;

    const agentType = parseAgentType();
    if (!STATIC_DEV_AGENTS.has(agentType)) return;

    const filePath: string =
      (event.input as { path?: string; file_path?: string }).path ??
      (event.input as { path?: string; file_path?: string }).file_path ??
      "";

    debugLog("static-site-ex-guard", `agent=${agentType} file=${filePath}`);

    if (/\.exs?$/.test(filePath)) {
      return deny(
        `BLOCKED by static-site-ex-guard: static-site developer "${agentType}" may not edit Elixir files (${filePath}).`
      );
    }
  });
}
