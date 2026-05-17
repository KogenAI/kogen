/**
 * developer-no-self-gate.ts — Pi enforcement: count CI/test invocations and
 * block after threshold.
 *
 * Mirrors: templates/shared/hooks/developer-no-self-gate.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

export const HANDLER_META = {
  name: "developer-no-self-gate",
  event: "tool_call",
  matcher: "bash",
} as const;

const DEV_AGENTS = new Set([
  "developer-phoenix-backend",
  "developer-phoenix-frontend",
  "developer-html",
  "developer-hugo",
  "developer-vite",
]);

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const agentType = parseAgentType();
    if (!DEV_AGENTS.has(agentType)) return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("developer-no-self-gate", `agent=${agentType} cmd=${command}`);

    if (
      !/\bmix\s+(test|credo|format)\b|\bmake\s+(ci|ci-fast|test)\b/.test(
        command,
      )
    ) {
      return;
    }

    const sessionId =
      (event as { sessionId?: string }).sessionId ??
      process.env["SESSION_ID"] ??
      "unknown";
    const counterFile = path.join(
      os.tmpdir(),
      `combobulate-self-gate-${sessionId}.count`,
    );

    let count = 0;
    try {
      const raw = fs.readFileSync(counterFile, "utf8").trim();
      count = parseInt(raw, 10) || 0;
    } catch {
      count = 0;
    }

    count += 1;
    fs.writeFileSync(counterFile, String(count));
    debugLog("developer-no-self-gate", `session=${sessionId} count=${count}`);

    if (count >= 3) {
      return deny(
        `BLOCKED by developer-no-self-gate: use dev-gate.sh handoff — return control to orchestrator. You have run CI/test commands ${count} times in this session. Complete your implementation and stop — the gate runs automatically via SubagentStop hook.`,
      );
    }
  });
}
