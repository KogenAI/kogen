/**
 * developer-no-self-gate-reset.ts — Pi enforcement: reset self-gate counter
 * on session_shutdown (SubagentStop equivalent).
 *
 * Mirrors: templates/shared/hooks/developer-no-self-gate-reset.sh
 * Event: session_shutdown (SubagentStop equivalent)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parseAgentType, debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

export const HANDLER_META = {
  name: "developer-no-self-gate-reset",
  event: "session_shutdown",
  matcher:
    "developer-phoenix-backend|developer-phoenix-frontend|developer-static",
} as const;

const DEV_AGENTS = new Set([
  "developer-phoenix-backend",
  "developer-phoenix-frontend",
  "developer-static",
]);

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async (event) => {
    const agentType = parseAgentType();
    if (!DEV_AGENTS.has(agentType)) return;

    const sessionId =
      (event as { sessionId?: string }).sessionId ??
      process.env["SESSION_ID"] ??
      "unknown";
    const counterFile = path.join(
      os.tmpdir(),
      `codegen-self-gate-${sessionId}.count`,
    );

    if (fs.existsSync(counterFile)) {
      fs.rmSync(counterFile, { force: true });
      debugLog(
        "developer-no-self-gate-reset",
        `removed counter_file=${counterFile}`,
      );
    }
  });
}
