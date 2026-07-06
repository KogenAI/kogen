/**
 * subagent-retrospective-guard.ts — Pi enforcement: warn when a subagent stops
 * without a ### What I Learned This Step block in its cycle log role event body.
 *
 * Mirrors: harnesses/claude/hooks/subagent-retrospective-guard.sh
 * Event: session_shutdown (SubagentStop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * Gate (agent type): only enforces for:
 *   developer-phoenix-backend, developer-phoenix-frontend,
 *   reviewer-phoenix, reviewer-static,
 *   planner-phoenix, planner-static
 *
 * Logic:
 *   Disk-scan for active cycle log (.jsonl) → parse JSON lines → concatenate
 *   the agent's role event `.body` (planner* matches any role startsWith
 *   "planner"; other roles match literally) plus any dedicated {"ev":"learned"}
 *   event text → check for ### What I Learned This Step header with ≥1
 *   non-blank line after it, OR a non-empty dedicated learned event (either
 *   satisfies the check).
 *
 * Skip when:
 *   - AGENT_TYPE not in matcher set
 *   - No active cycle log found
 *   - Agent has no role event in the log yet (defensive)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  debugLog,
  parseAgentType,
  getActiveStepLog,
} from "../lib/hook-helpers";
import * as fs from "node:fs";

export const HANDLER_META = {
  name: "subagent-retrospective-guard",
  event: "session_shutdown",
  matcher: "*",
} as const;

const MATCHED_AGENTS = new Set([
  "developer-phoenix-backend",
  "developer-phoenix-frontend",
  "reviewer-phoenix",
  "reviewer-static",
  "planner-phoenix",
  "planner-static",
]);

type CycleEvent = {
  ev?: string;
  role?: string;
  body?: string;
  text?: string;
};

/** Parse a .jsonl cycle log into its event objects, skipping malformed lines. */
function parseCycleLog(logContent: string): CycleEvent[] {
  const events: CycleEvent[] = [];
  for (const line of logContent.split("\n")) {
    if (!line.trim()) continue;
    try {
      events.push(JSON.parse(line) as CycleEvent);
    } catch {
      continue;
    }
  }
  return events;
}

/** Does any role event match this agent (planner* matches any role startsWith "planner")? */
function roleMatches(role: string | undefined, agentType: string): boolean {
  if (!role) return false;
  if (agentType.startsWith("planner")) return role.startsWith("planner");
  return role === agentType;
}

/** Concatenate every role-event body for this agent, in file order. */
function sectionBodyFor(events: CycleEvent[], agentType: string): string {
  return events
    .filter((e) => e.ev === "role" && roleMatches(e.role, agentType))
    .map((e) => e.body ?? "")
    .join("\n");
}

/** Concatenate every dedicated {"ev":"learned"} event text for this agent. */
function learnedEventsFor(events: CycleEvent[], agentType: string): string {
  return events
    .filter((e) => e.ev === "learned" && roleMatches(e.role, agentType))
    .map((e) => e.text ?? "")
    .join("\n");
}

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    debugLog("subagent-retrospective-guard", `agent=${agentType}`);

    // Only gate the matched roles.
    if (!MATCHED_AGENTS.has(agentType)) {
      debugLog(
        "subagent-retrospective-guard",
        `skip: agent=${agentType} not in matcher`,
      );
      return;
    }

    const projectDir = process.env["CWD"] ?? process.cwd();
    const logPath = getActiveStepLog(projectDir);

    if (!logPath) {
      debugLog("subagent-retrospective-guard", "skip: no active step log");
      return;
    }

    let logContent: string;
    try {
      logContent = fs.readFileSync(logPath, "utf8");
    } catch {
      debugLog("subagent-retrospective-guard", "skip: log unreadable");
      return;
    }

    debugLog(
      "subagent-retrospective-guard",
      `log=${logPath} agent=${agentType}`,
    );

    const events = parseCycleLog(logContent);

    // Check at least one role event exists for this agent (defensive — let
    // other guards catch true absence).
    const rolePresent = events.some(
      (e) => e.ev === "role" && roleMatches(e.role, agentType),
    );
    if (!rolePresent) {
      debugLog(
        "subagent-retrospective-guard",
        `skip: no role event found for ${agentType}`,
      );
      return;
    }

    const sectionBody = sectionBodyFor(events, agentType);
    const learnedEvents = learnedEventsFor(events, agentType);

    const hasRetroHeader = sectionBody.includes("### What I Learned This Step");
    const hasLearnedEvent = learnedEvents.split("\n").some((l) => l.trim());

    // Check for the retrospective header in the role body, OR a dedicated
    // learned event (either counts).
    if (!hasRetroHeader && !hasLearnedEvent) {
      process.stderr.write(
        `[pi-enforcement:subagent-retrospective-guard] WARNING: ${agentType} returned but its role event(s) in the step log are missing the '### What I Learned This Step' block (or a dedicated learned event). Add this before finishing. Minimal acceptable content: '- nothing notable'. Step log: ${logPath}\n`,
      );
      return;
    }

    // A dedicated learned event with non-empty text always satisfies the check.
    let hasContent: boolean;
    if (hasLearnedEvent) {
      hasContent = true;
      debugLog("subagent-retrospective-guard", "PASS: dedicated learned event present");
    } else {
      // Check at least one non-blank line follows the header in the role body.
      const learnedParts = sectionBody.split("### What I Learned This Step");
      const afterHeader = learnedParts.length > 1 ? learnedParts[1] : "";
      const nextH3Idx = afterHeader.indexOf("\n### ");
      const learnedBody =
        nextH3Idx >= 0 ? afterHeader.slice(0, nextH3Idx) : afterHeader;
      hasContent = learnedBody.split("\n").some((line) => line.trim());
    }

    if (!hasContent) {
      process.stderr.write(
        `[pi-enforcement:subagent-retrospective-guard] WARNING: ${agentType}'s '### What I Learned This Step' block exists but is empty. Add at least one bullet (minimum: '- nothing notable'). Step log: ${logPath}\n`,
      );
      return;
    }

    debugLog(
      "subagent-retrospective-guard",
      "PASS: retrospective block present and non-empty",
    );
  });
}
