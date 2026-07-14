/**
 * role-retrospective-before-stop.ts — Pi enforcement: warn when a
 * planner/developer/reviewer subagent stops without recording BOTH its work
 * (an {"ev":"role"} event with a non-empty body) and its learning (an
 * {"ev":"learned"} event clearing the non-triviality bar).
 *
 * Mirrors: harnesses/claude/hooks/role-retrospective-before-stop.sh
 * Event: session_shutdown (Stop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * Gate: only enforces when parseAgentType() matches planner-*, developer-*,
 * or reviewer-* (context-curator and committer are NOT gated).
 *
 * Validation:
 *   Disk-scan for active cycle log (.jsonl) → parse JSON lines → find the
 *   LAST {"ev":"role","role":<agentType>} event's `.body` (work) and the
 *   LAST {"ev":"learned","role":<agentType>} event's `.text` (learning).
 *   Warn if:
 *     - work body is empty/whitespace-only
 *     - learning text is absent, under 40 chars (trimmed), or normalizes to
 *       a placeholder ("nothing notable", "nothing", "none", "n/a",
 *       "no learnings")
 *
 * Skip when:
 *   - AGENT_TYPE does not match planner-, developer-, or reviewer- prefix
 *   - No cycle log found
 *   - Both work and learning are present and non-trivial
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

const PLACEHOLDER_TEXTS = new Set([
  "nothing notable",
  "nothing",
  "none",
  "n/a",
  "no learnings",
]);

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

/** Last {"ev":"learned","role":agentType} .text — empty string if none found. */
function lastLearnedText(events: RoleEvent[], agentType: string): string {
  let text = "";
  for (const e of events) {
    if (e.ev === "learned" && e.role === agentType) {
      text = e.text ?? "";
    }
  }
  return text;
}

function isLearningTrivial(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.length < 40) return true;
  const normalized = trimmed.toLowerCase().replace(/[.-]/g, "");
  return PLACEHOLDER_TEXTS.has(normalized);
}

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    debugLog("role-retrospective-before-stop", `agent_type=${agentType}`);

    if (!/^(planner-|developer-|reviewer-)/.test(agentType)) {
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
    const learnedText = lastLearnedText(events, agentType);
    const learningTrivial = isLearningTrivial(learnedText);

    const missingParts: string[] = [];
    if (!workBody) missingParts.push("work");
    if (learningTrivial) missingParts.push("learning");

    if (missingParts.length === 0) {
      debugLog("role-retrospective-before-stop", "allow: work + learning present");
      return;
    }

    const missing = missingParts.join(" and ");

    if (!workBody) {
      process.stderr.write(
        `[pi-enforcement:role-retrospective-before-stop] WARNING: ${agentType} stopped without recording its work this step. Run: printf '%s' "$body" | codegen-log section ${agentType} --learned "<what you learned>" --slug <slug>\n`,
      );
    } else {
      process.stderr.write(
        `[pi-enforcement:role-retrospective-before-stop] WARNING: ${agentType} stopped without recording what it learned this step (missing: ${missing}). Run: codegen-log append ${agentType} --learned "<text>" --slug <slug> — at least 40 characters, no placeholders ('nothing notable', 'none', 'n/a').\n`,
      );
    }
  });
}
