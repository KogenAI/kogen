/**
 * pitch-shipped-before-stop.ts — Pi enforcement: warn when pitch is still in
 * ready/ after commit (auto-ship mirror).
 *
 * Mirrors: harnesses/claude/hooks/pitch-shipped-before-stop.sh
 * Event: session_shutdown (Stop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * Bypass paths:
 *   Investigative role (shape/debug/ops/experiment/refactor) — isBuildMode() false
 *   process.env.CODEGEN_NO_AUTOSHIP               — explicit operator suppression
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog, getActiveStepLog } from "../lib/hook-helpers";
import { isBuildMode } from "./_role";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

export const HANDLER_META = {
  name: "pitch-shipped-before-stop",
  event: "session_shutdown",
  matcher: "*",
} as const;

/** Extract pitch slug from a cycle log filename: <ts>_<slug>_cycle.jsonl → slug. */
function slugFromLogName(logPath: string): string | null {
  const basename = path.basename(logPath);
  const match = /^[0-9]{8}_[0-9]{6}_(.+)_cycle\.jsonl$/.exec(basename);
  if (!match) return null;
  return match[1];
}

/** Parsed JSONL event — minimal shape needed by this hook. */
type CycleEvent = { ev?: string; pitch?: string; role?: string };

/** Parse a JSONL cycle log's lines into event objects, skipping malformed lines. */
function parseCycleEvents(logContent: string): CycleEvent[] {
  const events: CycleEvent[] = [];
  for (const line of logContent.split("\n")) {
    if (!line.trim()) continue;
    try {
      events.push(JSON.parse(line) as CycleEvent);
    } catch {
      // Skip malformed lines — fail-open per the fail-open discipline the
      // old markdown greps also had.
    }
  }
  return events;
}

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const sessionId = process.env["SESSION_ID"] ?? "unknown";
    const projectDir = process.env["CWD"] ?? process.cwd();
    const counterFile = path.join(
      os.tmpdir(),
      `claude-autoship-guard-${sessionId}.count`,
    );

    debugLog("pitch-shipped-before-stop", `session=${sessionId}`);

    // Build-mode gate — investigative roles never auto-ship.
    if (!isBuildMode()) {
      debugLog("pitch-shipped-before-stop", "skip: investigative role");
      return;
    }

    if (process.env["CODEGEN_NO_AUTOSHIP"]) {
      debugLog("pitch-shipped-before-stop", "skip: CODEGEN_NO_AUTOSHIP");
      return;
    }

    // Retry cap.
    let count = 0;
    try {
      count = parseInt(fs.readFileSync(counterFile, "utf8").trim(), 10) || 0;
    } catch {
      count = 0;
    }
    if (count >= 2) {
      fs.rmSync(counterFile, { force: true });
      return;
    }

    // Locate active step log.
    const logPath = getActiveStepLog(projectDir);
    if (!logPath) {
      debugLog("pitch-shipped-before-stop", "skip: no step log");
      return;
    }

    let logContent: string;
    try {
      logContent = fs.readFileSync(logPath, "utf8");
    } catch {
      debugLog("pitch-shipped-before-stop", "skip: log unreadable");
      return;
    }
    const events = parseCycleEvents(logContent);

    // Slug resolution: prefer the log's "init" event .pitch field, falling
    // back to a filename slug-capture for logs that predate an init event.
    const initEvent = events.find((e) => e.ev === "init" && e.pitch);
    const slug = initEvent?.pitch ?? slugFromLogName(logPath);
    if (!slug) {
      debugLog(
        "pitch-shipped-before-stop",
        "skip: no slug in init event or log filename",
      );
      return;
    }

    debugLog(
      "pitch-shipped-before-stop",
      `slug=${slug} log=${path.basename(logPath)}`,
    );

    // Only act after committer has committed.
    const committerPresent = events.some(
      (e) => e.ev === "role" && e.role === "committer",
    );
    if (!committerPresent) {
      debugLog("pitch-shipped-before-stop", "skip: committer role event absent");
      return;
    }

    // Check if THIS session's pitch (by slug) is still in ready/.
    const readyPath = path.join(
      projectDir,
      "codegen",
      "pitches",
      "ready",
      `${slug}.md`,
    );
    if (!fs.existsSync(readyPath)) {
      debugLog(
        "pitch-shipped-before-stop",
        `skip: ${slug}.md not in ready/ (already shipped or draft)`,
      );
      return;
    }

    count += 1;
    fs.writeFileSync(counterFile, String(count));

    process.stderr.write(
      `[pi-enforcement:pitch-shipped-before-stop] WARNING: Pitch ${slug}.md was committed but is still in codegen/pitches/ready/. Move it to shipped/: mv codegen/pitches/ready/${slug}.md codegen/pitches/shipped/${slug}.md (plain mv, NEVER git mv). Count: ${count}\n`,
    );
  });
}
