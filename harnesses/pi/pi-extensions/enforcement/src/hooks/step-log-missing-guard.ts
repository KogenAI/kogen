/**
 * step-log-missing-guard.ts — Pi enforcement: warn when session shuts down with
 * no canonical session log present in the logging directory.
 *
 * Mirrors: harnesses/claude/hooks/step-log-missing-guard.sh (REDUCED FIDELITY)
 * Event: session_shutdown (Stop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * REDUCED FIDELITY NOTE:
 * The claude original now uses POSITION-CORRELATION: it blocks only when the
 * LAST developer-* Agent tool_use has no step-log creation (Write/Edit/MultiEdit
 * to codegen/logging/*.md OR a Bash codegen-log init|section|append) AFTER it in
 * transcript order — so a resolved-and-logged delegation from an earlier cycle
 * stops arming the guard. Pi has no TRANSCRIPT_PATH and cannot inspect
 * transcript order, so this twin implements a weaker disk heuristic: if the
 * logging directory exists, was recently active (<60 minutes), and contains zero
 * canonical session log files, warn. This catches the "no log ever created"
 * case but cannot detect the position-correlation nuance (delegated-then-logged
 * vs. delegated-never-logged).
 *
 * SENTINEL NOTE (codegen/logging/.active): the Claude twin's belt-and-suspenders
 * check treats a fresh .active sentinel (written synchronously by codegen-log
 * init/relocate) as evidence equivalent to a transcript-position match, closing
 * an async-lag gap between a Bash codegen-log write and its transcript entry
 * landing. Pi's disk heuristic ALREADY reads the canonical log files directly —
 * the .active sentinel is strictly weaker evidence than the log file itself
 * (which this check already scans for), so it is NOT consulted here. Adding it
 * would not raise fidelity: if a canonical log exists on disk, the check below
 * already sees it regardless of whether .active also points at it.
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
  /^[0-9]{8}_[0-9]{6}(_[a-z0-9_-]+)?_(session|step[0-9]+_[a-z0-9_-]+)\.md$/;

const SIXTY_MIN_MS = 60 * 60 * 1000;

/** Resolve the active Pi role (PI_ROLE primary). Empty = build mode. */
function resolveRole(): string {
  return process.env["PI_ROLE"] ?? process.env["CLAUDE_ROLE"] ?? "";
}

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    // Investigative-mode skip: observe-only Stop twin enforces only in build mode
    // (empty role). Silent early-return on any non-empty role — no warning (mirrors
    // signal: CLAUDE_ROLE_FAMILY; misfire warning in investigative mode is noise).
    if (resolveRole() !== "") return;

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
