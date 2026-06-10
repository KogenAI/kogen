/**
 * step-log-missing-guard.ts — Pi enforcement: warn when session shuts down with
 * no canonical session log present in the logging directory.
 *
 * Mirrors: harnesses/claude/hooks/step-log-missing-guard.sh (REDUCED FIDELITY)
 * Event: session_shutdown (Stop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * REDUCED FIDELITY NOTE:
 * The claude original detects "developer-* Agent called but no Write to
 * codegen/logging/*.md in the session transcript" — a transcript-inspection
 * that Pi cannot perform (Pi has no TRANSCRIPT_PATH). This twin implements a
 * weaker heuristic: if the logging directory exists, was recently active
 * (<60 minutes), and contains zero canonical session log files, warn.
 * This catches the "no log ever created" case but cannot detect the
 * "developer ran but log was missing from transcript" nuance.
 *
 * Skip when:
 *   - codegen/logging/ directory does not exist
 *   - No recently modified (< 60 min) files in directory
 *   - Canonical session log(s) are present
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "step-log-missing-guard",
  event: "session_shutdown",
  matcher: "*",
} as const;

const CANONICAL_LOG_RE =
  /^[0-9]{8}_[0-9]{6}(_[a-z0-9-]+)?_(session|step[0-9]+_[a-z0-9-]+)\.md$/;

const SIXTY_MIN_MS = 60 * 60 * 1000;

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const projectDir = process.env["CWD"] ?? process.cwd();
    debugLog("step-log-missing-guard", `cwd=${projectDir}`);

    const loggingDir = path.join(projectDir, "codegen", "logging");
    if (!fs.existsSync(loggingDir)) {
      debugLog("step-log-missing-guard", "skip: no logging dir");
      return;
    }

    let files: string[];
    try {
      files = fs.readdirSync(loggingDir).filter((f) => f.endsWith(".md"));
    } catch {
      debugLog("step-log-missing-guard", "skip: could not read logging dir");
      return;
    }

    if (files.length === 0) {
      debugLog("step-log-missing-guard", "skip: no .md files in logging dir");
      return;
    }

    // Check if any file was recently modified.
    const now = Date.now();
    const recentFiles = files.filter((f) => {
      try {
        const mtime = fs.statSync(path.join(loggingDir, f)).mtimeMs;
        return now - mtime < SIXTY_MIN_MS;
      } catch {
        return false;
      }
    });

    if (recentFiles.length === 0) {
      debugLog("step-log-missing-guard", "skip: no recently modified files");
      return;
    }

    // Check if any canonical session log exists.
    const hasCanonical = files.some((f) => CANONICAL_LOG_RE.test(f));

    if (hasCanonical) {
      debugLog("step-log-missing-guard", "skip: canonical log present");
      return;
    }

    process.stderr.write(
      `[pi-enforcement:step-log-missing-guard] WARNING: codegen/logging/ has recently active files but no canonical session log (YYYYMMDD_HHMMSS[_slug]_session.md or _step<N>_<slug>.md). Per session-log rules, the orchestrator MUST create the step log FIRST using the Write tool before delegating to developer-* subagents. Template: codegen/logging/$(date -u +%Y%m%d_%H%M%S)_<slug>_session.md\n`,
    );
  });
}
