/**
 * stop-verify-planner-gate.ts — Pi enforcement: warn when a planner subagent
 * stops without a valid structured plan_gate declaration, or without a
 * typed plan event, in its cycle log.
 *
 * Mirrors: harnesses/claude/hooks/stop-verify-planner-gate.sh (+
 * lib/gate-select.sh gate_select_read_planner_gate / gate_select_read_planner_plan)
 * Event: session_shutdown (SubagentStop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr. The
 * Elixir loop's `OrchestrationLoop.resolve_planner_plan!/2` is the
 * fail-closed backstop that covers Pi (it raises before invoking a
 * developer when no plan event is present).
 *
 * Gate: only enforces when parseAgentType() matches /^planner-/.
 *
 * Validation:
 *   Disk-scan for active cycle log (.jsonl) → parse JSON lines → find the
 *   LAST {"ev":"plan_gate","role":<planner*>,"command":...,"mode":...,
 *   "timeout":...} event AND the LAST {"ev":"plan","role":<planner*>,
 *   "plan":...} event — both first-class structured events written via
 *   `codegen-log append <role> --plan-gate @-` / `--plan @-`, never
 *   re-parsed out of the planner's free-form role body prose (session-log.md
 *   § the body is opaque, never re-parsed as structure). Warn if:
 *     - no plan_gate event exists for a planner* role
 *     - its "command" field matches the placeholder denylist (TBD, pending,
 *       <...>, etc.)
 *     - no plan event (or a blank one) exists for a planner* role
 *
 * Skip when:
 *   - AGENT_TYPE does not match planner-*
 *   - No cycle log found
 *   - A plan_gate event is present with a non-placeholder command AND a
 *     non-blank plan event is present
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
 * Read the LAST {"ev":"plan_gate","role":<planner*>,...} JSONL event's
 * "command" field, in file order — mirrors gate_select_read_planner_gate
 * (gate-select.sh). Malformed lines are skipped (fail-open on a possibly-
 * partial append-only file). Empty string when no such event exists.
 */
function readPlannerGate(logContent: string): string {
  let command = "";
  for (const line of logContent.split("\n")) {
    if (!line.trim()) continue;
    let obj: { ev?: string; role?: string; command?: string };
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (
      obj.ev === "plan_gate" &&
      (obj.role ?? "").startsWith("planner") &&
      typeof obj.command === "string" &&
      obj.command.length > 0
    ) {
      command = obj.command;
    }
  }
  return command;
}

/**
 * Read the LAST {"ev":"plan","role":<planner*>,"plan":...} JSONL event's
 * "plan" field, in file order — mirrors gate_select_read_planner_plan
 * (gate-select.sh). Malformed lines are skipped (fail-open on a possibly-
 * partial append-only file). Empty string when no such event exists.
 */
function readPlannerPlan(logContent: string): string {
  let plan = "";
  for (const line of logContent.split("\n")) {
    if (!line.trim()) continue;
    let obj: { ev?: string; role?: string; plan?: string };
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (
      obj.ev === "plan" &&
      (obj.role ?? "").startsWith("planner") &&
      typeof obj.plan === "string"
    ) {
      plan = obj.plan;
    }
  }
  return plan;
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

    // Warn if no plan_gate event exists (empty command).
    if (!gateValue) {
      process.stderr.write(
        `[pi-enforcement:stop-verify-planner-gate] WARNING: planner stopped with no plan_gate event in ${logPath}. Per codegen/rules/roles/planner.md Outputs (1), planner MUST declare the exact gate command before Stop via \`codegen-log append <role> --plan-gate @-\`, then return.\n`,
      );
      return;
    }

    // Warn if gate matches placeholder denylist.
    if (PLACEHOLDER_RE.test(gateValue) || ANGLE_BRACKET_RE.test(gateValue)) {
      process.stderr.write(
        `[pi-enforcement:stop-verify-planner-gate] WARNING: planner stopped with a placeholder plan_gate command ("${gateValue}") in ${logPath}. Per codegen/rules/roles/planner.md Outputs (1), planner MUST declare the exact gate command before Stop via \`codegen-log append <role> --plan-gate @-\`, then return.\n`,
      );
      return;
    }

    // Warn if no non-blank plan event exists — the typed plan marker, never
    // re-parsed out of the free-form role body prose.
    const planValue = readPlannerPlan(logContent);
    debugLog(
      "stop-verify-planner-gate",
      `plan_present=${planValue.trim() ? "yes" : "no"}`,
    );

    if (!planValue.trim()) {
      process.stderr.write(
        `[pi-enforcement:stop-verify-planner-gate] WARNING: planner stopped with no {"ev":"plan"} event in ${logPath} — write your plan via 'codegen-log append <role> --plan @-' before stopping.\n`,
      );
      return;
    }

    debugLog(
      "stop-verify-planner-gate",
      `allow: gate=${gateValue} plan_present=yes`,
    );
  });
}
