/**
 * step-log-section-before-spawn.ts — Pi enforcement: require cycle log +
 * required role event before any subagent spawn.
 *
 * Mirrors: harnesses/claude/hooks/step-log-section-before-spawn.sh
 * Event: tool_call
 * Matcher: subagent (BLOCKING via deny())
 *
 * Logic:
 *   Read subagent_type from tool input.
 *   Map planner-* → any role event whose "role" startsWith "planner";
 *   anything else → the subagent_type itself (literal role match).
 *   Locate active cycle log via getActiveStepLog().
 *   If no log found → deny ("create step log FIRST")
 *   If log exists but expected role event absent → deny (naming the missing role)
 *   Else → allow
 *
 * Fail-open: only when no log path resolves at all (log dir/file absent).
 * A log path that resolves but throws on read (present-but-unreadable) denies —
 * an unreadable log cannot prove the required role event exists.
 *
 * REDUCED FIDELITY NOTE: Pi has no transcript access, so this twin cannot
 * emit the Claude original's diagnostic breadcrumb file. The core role-event
 * + prior-stage-body checks are otherwise mirrored line-for-line against the
 * Claude jq contract (role startsWith("planner") OR role===need).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, getActiveStepLog } from "../lib/hook-helpers";
import { isBuildMode } from "./_role";
import * as fs from "node:fs";

export const HANDLER_META = {
  name: "step-log-section-before-spawn",
  event: "tool_call",
  matcher: "subagent",
} as const;

type CycleEvent = {
  ev?: string;
  role?: string;
  body?: string;
};

/** Parse a .jsonl cycle log into its event objects, skipping malformed lines. */
function parseCycleLog(logContent: string): CycleEvent[] {
  const events: CycleEvent[] = [];
  for (const line of logContent.split("\n")) {
    if (!line.trim()) continue;
    try {
      events.push(JSON.parse(line) as CycleEvent);
    } catch {
      // Malformed/partial line (append-only file mid-write) — skip.
      continue;
    }
  }
  return events;
}

/** Does at least one "role" event match the expected role token? */
function roleEventPresent(events: CycleEvent[], need: string): boolean {
  if (need.startsWith("planner")) {
    return events.some(
      (e) => e.ev === "role" && (e.role ?? "").startsWith("planner"),
    );
  }
  return events.some((e) => e.ev === "role" && e.role === need);
}

/**
 * Return true when the given role has at least one non-heading body line
 * across ALL its role events (concatenated in file order), excluding the
 * "### What I Learned This Step" retrospective block (which is not real
 * content on its own). Any other "### " line (e.g. a verdict marker like
 * "### FINAL VERDICT — APPROVED") counts as body content.
 */
function roleHasBody(events: CycleEvent[], role: string): boolean {
  const bodies = events
    .filter((e) => e.ev === "role" && e.role === role)
    .map((e) => e.body ?? "");

  for (const body of bodies) {
    const lines = body.split("\n");
    let inRetro = false;
    for (const line of lines) {
      if (line.startsWith("### What I Learned")) {
        inRetro = true;
        continue;
      }
      if (inRetro && line.trim() === "") continue;
      if (inRetro && /^\s*[-*]/.test(line)) continue;
      if (inRetro) inRetro = false;
      if (line.trim() === "") continue;
      return true;
    }
  }

  return false;
}

/** Map subagent_type → the role whose body must be non-empty before it may spawn. */
function priorRoleFor(subagentType: string): string {
  if (subagentType.startsWith("developer-")) return "planner"; // startsWith match below
  if (subagentType.startsWith("reviewer-")) return "developer-"; // startsWith match below
  if (subagentType === "context-curator") return "reviewer-"; // startsWith match below
  if (subagentType === "committer") return "context-curator";
  return "";
}

/** Find the last role event whose role startsWith the given prefix. */
function lastRoleStartingWith(events: CycleEvent[], prefix: string): string {
  let last = "";
  for (const e of events) {
    if (e.ev === "role" && (e.role ?? "").startsWith(prefix)) {
      last = e.role ?? "";
    }
  }
  return last;
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "subagent") return;

    if (!isBuildMode()) return;

    const subagentType: string =
      (event.input as { agent?: string; subagent_type?: string }).agent ??
      (event.input as { agent?: string; subagent_type?: string })
        .subagent_type ??
      "";

    debugLog("step-log-section-before-spawn", `subagent_type=${subagentType}`);

    const need = subagentType;
    debugLog("step-log-section-before-spawn", `need=${need}`);

    // Locate active cycle log — fail-open if missing.
    const projectDir = process.env["CWD"] ?? process.cwd();
    const logPath = getActiveStepLog(projectDir);

    if (!logPath) {
      debugLog(
        "step-log-section-before-spawn",
        "no step log found — deny (create log first)",
      );
      return deny(
        `BLOCKED: no step log found. Create the step log FIRST before spawning ${subagentType}. Step 0 is non-negotiable: run codegen-log init, THEN write the '${need}' role event, THEN spawn.`,
      );
    }

    let logContent: string;
    try {
      logContent = fs.readFileSync(logPath, "utf8");
    } catch (e) {
      debugLog(
        "step-log-section-before-spawn",
        `deny: log path resolved but unreadable: ${(e as Error).message}`,
      );
      return deny(
        `BLOCKED: step log ${logPath} was located but could not be read (${(e as Error).message}). Cannot verify the '${need}' role event before spawning ${subagentType} — fix the log read error first.`,
      );
    }

    debugLog("step-log-section-before-spawn", `log=${logPath}`);

    const events = parseCycleLog(logContent);

    if (roleEventPresent(events, need)) {
      // Fail closed on empty-body role events: the next role may not spawn
      // until the prior required stage's role event has real body content.
      const priorPrefix = priorRoleFor(subagentType);
      const priorRole = priorPrefix
        ? subagentType === "committer"
          ? priorPrefix
          : lastRoleStartingWith(events, priorPrefix)
        : "";

      if (priorRole && !roleHasBody(events, priorRole)) {
        return deny(
          `BLOCKED: '${priorRole}' role event exists in the step log but its body is empty — the prior stage produced no real content (subagent likely died). Recover: re-spawn the dead stage, produce real output, then retry. Do not skip a stage because the subagent died.`,
        );
      }

      debugLog("step-log-section-before-spawn", "allow: role event present with body content");
      return;
    }

    return deny(
      `BLOCKED: missing '${need}' role event in step log before spawning ${subagentType}. Run codegen-log section ${need} immediately before this Agent() call, then retry.`,
    );
  });
}
