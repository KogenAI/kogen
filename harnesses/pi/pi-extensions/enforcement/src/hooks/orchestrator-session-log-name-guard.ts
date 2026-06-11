/**
 * orchestrator-session-log-name-guard.ts — Pi enforcement: deny non-canonical
 * session-log filenames when the orchestrator writes to codegen/logging/.
 *
 * Mirrors: harnesses/claude/hooks/orchestrator-session-log-name-guard.sh
 * Event: tool_call
 * Matcher: write|edit
 *
 * Only enforces when AGENT_TYPE is empty AND AGENT_ID is empty (orchestrator level).
 * Subagents (any non-empty AGENT_TYPE or AGENT_ID) pass through.
 * ops mode (CLAUDE_ROLE=ops / PI_ROLE=ops) bypasses — full access on live boxes.
 *
 * Only fires on Write|Edit to paths under codegen/logging/.
 * Non-logging Writes pass through.
 *
 * Allowlist (regex, anchored):
 *   codegen/logging/<YYYYMMDD>_<HHMMSS>[_<slug>]_session.md   — single/free-form
 *   codegen/logging/<YYYYMMDD>_<HHMMSS>_step<N>_<slug>.md     — step-queue
 *   codegen/logging/<YYYYMMDD>_progress.md                     — multi-step progress tracker
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, repoRelative } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "orchestrator-session-log-name-guard",
  event: "tool_call",
  matcher: "write|edit",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (!(event.toolName === "write" || event.toolName === "edit")) return;

    const agentType = process.env["AGENT_TYPE"] ?? "";
    const agentId = process.env["AGENT_ID"] ?? "";

    debugLog(
      "orchestrator-session-log-name-guard",
      `agent_type=${agentType} agent_id=${agentId}`,
    );

    // ops mode bypass.
    const piRole = process.env["PI_ROLE"] ?? "";
    const claudeRole = process.env["CLAUDE_ROLE"] ?? "";
    if (piRole === "ops" || claudeRole === "ops") {
      debugLog("orchestrator-session-log-name-guard", "skip: ops bypass");
      return;
    }

    // Only enforce for orchestrator level (both AGENT_TYPE and AGENT_ID empty).
    if (agentType !== "" || agentId !== "") {
      debugLog(
        "orchestrator-session-log-name-guard",
        `skip: subagent (agent_type=${agentType} agent_id=${agentId})`,
      );
      return;
    }

    const filePath: string =
      (event.input as { file_path?: string }).file_path ?? "";

    debugLog("orchestrator-session-log-name-guard", `file=${filePath}`);

    // Normalise to repo-relative path, strip leading ./
    let rel = repoRelative(filePath);
    if (rel.startsWith("./")) rel = rel.slice(2);

    // Non-logging paths: pass through.
    if (!/^codegen\/logging\//.test(rel)) {
      debugLog(
        "orchestrator-session-log-name-guard",
        `skip: not a session log path (${rel})`,
      );
      return;
    }

    // Allowlist: canonical session-log name forms.
    if (
      /^codegen\/logging\/([0-9]{8}_[0-9]{6}(_[a-z0-9_-]+)?_(session|step[0-9]+_[a-z0-9_-]+)|[0-9]{8}_progress)\.md$/.test(
        rel,
      )
    ) {
      debugLog(
        "orchestrator-session-log-name-guard",
        `allow: canonical session log (${rel})`,
      );
      return;
    }

    return deny(
      `Session log name must be codegen/logging/<YYYYMMDD>_<HHMMSS>_<slug>_session.md (single/multi-pitch) or _step<N>_<slug>.md (stepped) or <YYYYMMDD>_progress.md. Run \`date -u +%Y%m%d_%H%M%S\` for the timestamp, then Write that path. Got: ${filePath}`,
    );
  });
}
