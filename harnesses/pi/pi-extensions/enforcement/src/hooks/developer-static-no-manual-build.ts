/**
 * developer-static-no-manual-build.ts — Pi enforcement: developer-static may not run static build/verify commands manually (gate owns verification).
 *
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
 * Edit registry.yaml and run `make install` to regenerate.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, isCodegenLogWrite } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "developer-static-no-manual-build",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const agentType = process.env["AGENT_TYPE"] ?? "";
    if (!(agentType === "developer-static")) return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("developer-static-no-manual-build", `cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match or
    // counter increment.
    if (isCodegenLogWrite(command)) return;

    if (/(render|wiring)-check\.js|npm\s+(run\s+)?(build|serve)|vite\s+build|playwright/.test(command)) {
      return deny(
        "BLOCKED by developer-static-no-manual-build: do not run build/render/wiring-check/serve/playwright manually. LoopGate runs static-site verification automatically in the build loop after the developer role. Manual runs cause thrash.",
      );
    }
  });
}
