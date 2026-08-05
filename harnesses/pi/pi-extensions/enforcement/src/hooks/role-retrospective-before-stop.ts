/**
 * role-retrospective-before-stop.ts — Pi enforcement: warn when a
 * developer/reviewer subagent stops without recording BOTH its work
 * (an {"ev":"role"} event with a non-empty body) and its learning — either
 * an {"ev":"learned"} event or an {"ev":"no_learning"} event (the legal,
 * countable "this turn produced nothing to learn" exit).
 *
 * Substance (not length) is enforced at the writer — codegen-log refuses a
 * placeholder or compliance-echo text before it ever reaches the log; this
 * hook only checks PRESENCE of one of the two event kinds.
 *
 * Mirrors: harnesses/claude/hooks/role-retrospective-before-stop.sh
 * Event: session_shutdown (Stop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * Gate: only enforces when parseAgentType() matches developer-*
 * or reviewer-* (context-curator and committer are NOT gated).
 *
 * Validation:
 *   Disk-scan for active cycle log (.jsonl) → parse JSON lines → find the
 *   LAST {"ev":"role","role":<agentType>} event's `.body` (work) and check
 *   for the presence of ANY {"ev":"learned"|"no_learning","role":<agentType>}
 *   event (learning).
 *   Warn if:
 *     - work body is empty/whitespace-only
 *     - neither a learned nor a no_learning event exists for this role
 *
 * Skip when:
 *   - AGENT_TYPE does not match the developer- or reviewer- prefix
 *   - No cycle log found
 *   - Both work and learning are present
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  debugLog,
  parseAgentType,
  getActiveStepLog,
} from "../lib/hook-helpers";
import * as fs from "node:fs";

export const HANDLER_META = {
  name: "role-retrospective-before-stop",
  event: "session_shutdown",
  matcher: "*",
} as const;

interface RoleEvent {
  ev?: string;
  role?: string;
  body?: string;
  text?: string;
}

function parseLogLines(logContent: string): RoleEvent[] {
  const events: RoleEvent[] = [];
  for (const line of logContent.split("\n")) {
    if (!line.trim()) continue;
    try {
      events.push(JSON.parse(line) as RoleEvent);
    } catch {
      continue;
    }
  }
  return events;
}

/** Last {"ev":"role","role":agentType} .body — empty string if none found. */
function lastWorkBody(events: RoleEvent[], agentType: string): string {
  let body = "";
  for (const e of events) {
    if (e.ev === "role" && e.role === agentType) {
      body = e.body ?? "";
    }
  }
  return body;
}

/**
 * Presence of EITHER an {"ev":"learned"} or {"ev":"no_learning"} event for
 * this role. Substance is enforced at the writer (codegen-log refuses
 * placeholder/compliance-echo text before it lands) — this check is
 * presence-only, never a re-judgment of content quality.
 */
function hasLearningEvent(events: RoleEvent[], agentType: string): boolean {
  return events.some(
    (e) =>
      (e.ev === "learned" || e.ev === "no_learning") && e.role === agentType,
  );
}

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    debugLog("role-retrospective-before-stop", `agent_type=${agentType}`);

    if (!/^(developer-|reviewer-)/.test(agentType)) {
      debugLog(
        "role-retrospective-before-stop",
        `skip: agent_type=${agentType} not gated`,
      );
      return;
    }

    const projectDir = process.env["CWD"] ?? process.cwd();
    const logPath = getActiveStepLog(projectDir);

    if (!logPath) {
      debugLog("role-retrospective-before-stop", "skip: no cycle log resolved");
      return;
    }

    let logContent: string;
    try {
      logContent = fs.readFileSync(logPath, "utf8");
    } catch {
      debugLog("role-retrospective-before-stop", "skip: log unreadable");
      return;
    }

    const events = parseLogLines(logContent);
    const workBody = lastWorkBody(events, agentType).trim();
    const learningPresent = hasLearningEvent(events, agentType);

    const missingParts: string[] = [];
    if (!workBody) missingParts.push("work");
    if (!learningPresent) missingParts.push("learning");

    if (missingParts.length === 0) {
      debugLog("role-retrospective-before-stop", "allow: work + learning present");
      return;
    }

    const missing = missingParts.join(" and ");

    if (!workBody) {
      process.stderr.write(
        `[pi-enforcement:role-retrospective-before-stop] WARNING: ${agentType} stopped without recording its work this step. Run: printf '%s' "$body" | codegen-log section ${agentType} --learned "[local] <what you learned>" --slug <slug>\n`,
      );
    } else {
      process.stderr.write(
        `[pi-enforcement:role-retrospective-before-stop] WARNING: ${agentType} stopped without recording what it learned this step (missing: ${missing}). Record one specific thing this turn taught you. If this turn genuinely produced nothing to learn, say so: codegen-log append ${agentType} --no-learning "<what the turn did instead>" --slug <slug>.\n`,
      );
    }
  });
}
