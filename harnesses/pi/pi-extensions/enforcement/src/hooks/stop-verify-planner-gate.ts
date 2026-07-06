/**
 * stop-verify-planner-gate.ts — Pi enforcement: warn when a planner subagent
 * stops without a valid **Gate**: declaration in its cycle log role event body.
 *
 * Mirrors: harnesses/claude/hooks/stop-verify-planner-gate.sh (+ lib/gate-select.sh
 * planner_body_from_log)
 * Event: session_shutdown (SubagentStop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * Gate: only enforces when parseAgentType() matches /^planner-/.
 *
 * Validation:
 *   Disk-scan for active cycle log (.jsonl) → parse JSON lines → concatenate
 *   the `.body` of every {"ev":"role","role":<planner*>} event (in file
 *   order) → run the SAME **Gate**:/gate-json extraction on that prose,
 *   since planners still write "## Plan" / "**Gate**:" markdown prose INSIDE
 *   the opaque body string (never re-parsed as JSONL structure).
 *   Warn if:
 *     - gate-json fenced block is malformed JSON
 *     - **Gate**: is absent or empty
 *     - **Gate**: value matches placeholder denylist (TBD, pending, <...>, etc.)
 *
 * Skip when:
 *   - AGENT_TYPE does not match planner-*
 *   - No cycle log found, or it carries no planner role event
 *   - **Gate**: is present and not a placeholder
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  debugLog,
  parseAgentType,
  getActiveStepLog,
} from "../lib/hook-helpers";
import * as fs from "node:fs";

export const HANDLER_META = {
  name: "stop-verify-planner-gate",
  event: "session_shutdown",
  matcher: "*",
} as const;

/**
 * Concatenate the `.body` of every {"ev":"role","role":<planner*>} JSONL
 * event in the cycle log, in file order, joined by newlines — mirrors
 * `planner_body_from_log` (gate-select.sh). Malformed lines are skipped
 * (fail-open on a possibly-partial append-only file).
 */
function plannerBodyFromLog(logContent: string): string {
  const bodies: string[] = [];
  for (const line of logContent.split("\n")) {
    if (!line.trim()) continue;
    let obj: { ev?: string; role?: string; body?: string };
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (obj.ev === "role" && (obj.role ?? "").startsWith("planner")) {
      bodies.push(obj.body ?? "");
    }
  }
  return bodies.join("\n");
}

/**
 * Parse the gate value from the concatenated planner role body prose.
 * Returns:
 *   - the gate value string if found and valid
 *   - "" if **Gate**: is absent or empty
 *   - "__GATE_PARSE_ERROR__:<reason>" if gate-json block is malformed
 */
function readPlannerGate(logContent: string): string {
  const planSection = plannerBodyFromLog(logContent);

  // Check for ```gate-json fenced block after **Gate**:
  const gateJsonMatch = planSection.match(
    /\*\*Gate\*\*:\s*\n+```gate-json\n([\s\S]*?)```/m,
  );
  if (gateJsonMatch) {
    const rawJson = gateJsonMatch[1].trim();
    try {
      const parsed = JSON.parse(rawJson) as Record<string, unknown>;
      // Require command, mode, timeout fields.
      if (
        typeof parsed.command !== "string" ||
        typeof parsed.mode !== "string" ||
        (typeof parsed.timeout !== "string" &&
          typeof parsed.timeout !== "number")
      ) {
        return "__GATE_PARSE_ERROR__:gate-json missing required fields: command (string), mode (string), timeout (string|number)";
      }
      return parsed.command;
    } catch (e) {
      return `__GATE_PARSE_ERROR__:invalid JSON: ${String(e)}`;
    }
  }

  // Fallback: prose **Gate**: <value> line.
  const gateLineMatch = planSection.match(/^\*\*Gate\*\*:\s*(.+)$/m);
  if (gateLineMatch) {
    return gateLineMatch[1].trim();
  }

  return "";
}

const PLACEHOLDER_RE = /^(tbd|pending|to be determined|todo)$/i;
const ANGLE_BRACKET_RE = /^<.*>$/;

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    debugLog("stop-verify-planner-gate", `agent_type=${agentType}`);

    // Only enforce for planner-* subagents.
    if (!/^planner-/.test(agentType)) {
      debugLog(
        "stop-verify-planner-gate",
        `skip: agent_type=${agentType} is not planner-*`,
      );
      return;
    }

    const projectDir = process.env["CWD"] ?? process.cwd();
    const logPath = getActiveStepLog(projectDir);

    if (!logPath) {
      debugLog("stop-verify-planner-gate", "skip: no step log found");
      return;
    }

    debugLog("stop-verify-planner-gate", `resolved log=${logPath}`);

    let logContent: string;
    try {
      logContent = fs.readFileSync(logPath, "utf8");
    } catch {
      debugLog("stop-verify-planner-gate", "skip: log unreadable");
      return;
    }

    const gateValue = readPlannerGate(logContent);

    debugLog("stop-verify-planner-gate", `gate_value=${gateValue}`);

    // Warn if gate-json block parse error.
    if (gateValue.startsWith("__GATE_PARSE_ERROR__:")) {
      const parseReason = gateValue.slice("__GATE_PARSE_ERROR__:".length);
      process.stderr.write(
        `[pi-enforcement:stop-verify-planner-gate] WARNING: planner stopped with a malformed \`\`\`gate-json block in \`## Plan\` of ${logPath}: ${parseReason}. Fix the gate-json block so it is valid JSON with required fields command, mode, timeout (all strings/integers), then return.\n`,
      );
      return;
    }

    // Warn if gate is empty.
    if (!gateValue) {
      process.stderr.write(
        `[pi-enforcement:stop-verify-planner-gate] WARNING: planner stopped with \`**Gate**:\` missing or placeholder in \`## Plan\` of ${logPath}. Per codegen/rules/roles/planner.md Outputs (1), planner MUST declare exact gate command before Stop. Edit step log to set a \`\`\`gate-json block or \`**Gate**: <make target>\` inside ## Plan, then return.\n`,
      );
      return;
    }

    // Warn if gate matches placeholder denylist.
    if (PLACEHOLDER_RE.test(gateValue) || ANGLE_BRACKET_RE.test(gateValue)) {
      process.stderr.write(
        `[pi-enforcement:stop-verify-planner-gate] WARNING: planner stopped with \`**Gate**:\` missing or placeholder in \`## Plan\` of ${logPath}. Per codegen/rules/roles/planner.md Outputs (1), planner MUST declare exact gate command before Stop. Edit step log to set \`**Gate**: <make target>\` inside ## Plan, then return.\n`,
      );
      return;
    }

    debugLog("stop-verify-planner-gate", `allow: gate=${gateValue}`);
  });
}
