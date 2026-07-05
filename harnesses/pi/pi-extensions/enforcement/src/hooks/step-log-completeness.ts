/**
 * step-log-completeness.ts — Pi enforcement: warn if session shuts down with
 * incomplete delegation cycle (Stop equivalent).
 *
 * Mirrors: templates/shared/hooks/step-log-completeness.sh
 * Event: session_shutdown (Stop equivalent)
 *
 * Note: In Pi, session_shutdown cannot block. This logs a warning to stderr.
 *
 * REDUCED-FIDELITY: Pi's session_shutdown is observe-only; this twin cannot block.
 * Content-floor is enforced by the Claude Stop hook (step-log-completeness.sh).
 * This warning is for operator visibility only. Pi also lacks transcript access,
 * so the "active" log is the most-recently-modified file, which may differ from
 * the true session log.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog } from "../lib/hook-helpers";
import { isBuildMode } from "./_role";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "step-log-completeness",
  event: "session_shutdown",
  matcher: "*",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    // Investigative-mode skip: observe-only Stop twin enforces only in build
    // mode. Silent early-return on any investigative role — no warning (mirrors
    // signal: CLAUDE_ROLE_FAMILY; misfire warning in investigative mode is noise).
    if (!isBuildMode()) return;

    const projectDir = process.env["CWD"] ?? process.cwd();
    debugLog("step-log-completeness", `cwd=${projectDir}`);

    const loggingDir = path.join(projectDir, "codegen", "logging");
    if (!fs.existsSync(loggingDir)) return;

    const logFiles = fs
      .readdirSync(loggingDir)
      .filter((f) => f.endsWith(".md") && !f.includes("progress"))
      .map((f) => ({
        name: f,
        mtime: fs.statSync(path.join(loggingDir, f)).mtimeMs,
      }))
      .sort((a, b) => b.mtime - a.mtime);

    if (logFiles.length === 0) return;

    const activeLog = path.join(loggingDir, logFiles[0].name);

    // Only check recently modified logs (within last 60 min)
    const SIXTY_MIN_MS = 60 * 60 * 1000;
    if (Date.now() - logFiles[0].mtime > SIXTY_MIN_MS) return;

    let logContent: string;
    try {
      logContent = fs.readFileSync(activeLog, "utf8");
    } catch (e) {
      // activeLog was proven present via readdirSync/statSync above — a read
      // throw here is an unexpected fs failure, not absence. This hook is
      // observe-only (session_shutdown cannot block), so surface loudly
      // rather than silently skipping the completeness check.
      process.stderr.write(
        `[pi-enforcement:step-log-completeness] INCONCLUSIVE: active log ${activeLog} was located but could not be read (${(e as Error).message}). Completeness check skipped.\n`,
      );
      return;
    }

    if (logContent.includes("INCONCLUSIVE ⚠️")) return;

    // Skip when a death marker is present — orchestrator is mid-recovery.
    // Mirrors the death-marker skip in step-log-completeness.sh.
    if (
      logContent.includes("### INTERRUPTED ⚠️") ||
      logContent.includes("### ABORTED 💀")
    ) {
      debugLog(
        "step-log-completeness",
        "skip: death marker in log (in recovery)",
      );
      return;
    }

    const hasDeveloper = /## developer.*Section/i.test(logContent);
    let hasAllClear = /ALL CLEAR ✅/.test(logContent);
    const hasReviewer = /## reviewer.*Section/i.test(logContent);
    const hasCurator = /## context-curator.*Section/i.test(logContent);
    const hasCommitter = /## committer.*Section/i.test(logContent);

    // Reconcile ALL CLEAR with gate-result.json verdict field
    const gateResultPath = path.join(
      projectDir,
      "codegen",
      "gate-pending",
      "gate-result.json",
    );
    if (fs.existsSync(gateResultPath)) {
      // gateResultPath was proven present via existsSync above — separate the
      // read from the parse so an unreadable-but-present file surfaces its own
      // diagnostic distinct from malformed-JSON (a legitimate "present but
      // garbled" case that falls back to the log marker).
      let gateResultRaw: string | undefined;
      try {
        gateResultRaw = fs.readFileSync(gateResultPath, "utf8");
      } catch (e) {
        process.stderr.write(
          `[pi-enforcement:step-log-completeness] INCONCLUSIVE: gate-result.json at ${gateResultPath} was located but could not be read (${(e as Error).message}). Falling back to log marker for ALL CLEAR.\n`,
        );
      }
      if (gateResultRaw !== undefined) {
        try {
          const gateResult = JSON.parse(gateResultRaw) as { verdict?: string };
          if (gateResult.verdict === "clear") {
            hasAllClear = true; // gate-result.json authoritative clear
          } else if (
            gateResult.verdict === "failed" ||
            gateResult.verdict === "inconclusive"
          ) {
            hasAllClear = false; // gate-result.json overrides stale log marker
          }
        } catch {
          // malformed gate-result.json — use log marker only
        }
      }
    }

    if (hasDeveloper && hasAllClear && !hasReviewer) {
      process.stderr.write(
        "[pi-enforcement:step-log-completeness] WARNING: developer ALL CLEAR present but reviewer section absent — cycle incomplete.\n",
      );
    } else if (hasReviewer && !hasCurator) {
      process.stderr.write(
        "[pi-enforcement:step-log-completeness] WARNING: reviewer section present but context-curator section absent — cycle incomplete.\n",
      );
    } else if (hasReviewer && hasCurator && !hasCommitter) {
      process.stderr.write(
        "[pi-enforcement:step-log-completeness] WARNING: reviewer and context-curator sections present but committer section absent — cycle incomplete.\n",
      );
    }

    // REDUCED-FIDELITY observe-only content-floor: warn when the most-recently-
    // completed section appears to have no real body (suspected subagent death).
    // The Claude Stop hook (step-log-completeness.sh) enforces this with a block;
    // here we can only warn.
    const _extractSectionBody = (header: RegExp): string => {
      const lines = logContent.split("\n");
      let found = false;
      let inRetro = false;
      const body: string[] = [];
      for (const line of lines) {
        if (found) {
          if (/^## /.test(line)) break;
          if (/^### What I Learned/.test(line)) {
            inRetro = true;
            continue;
          }
          if (inRetro && line.trim() === "") continue;
          if (inRetro && /^\s*[-*]/.test(line)) continue;
          if (inRetro) inRetro = false;
          if (!/^###/.test(line) && line.trim() !== "") {
            body.push(line);
          }
        } else if (header.test(line)) {
          found = true;
        }
      }
      return body.join("\n").trim();
    };

    // Check the most-recently-completed section for empty/near-empty body.
    let _suspectHeader: RegExp | null = null;
    let _suspectName = "";
    if (hasReviewer && hasCurator && hasCommitter) {
      // Full cycle — no floor check needed
    } else if (hasReviewer && hasCurator) {
      _suspectHeader = /^## context-curator.*Section/i;
      _suspectName = "context-curator";
    } else if (hasReviewer) {
      _suspectHeader = /^## reviewer.*Section/i;
      _suspectName = "reviewer";
    } else if (hasDeveloper) {
      _suspectHeader = /^## developer.*Section/i;
      _suspectName = "developer";
    }

    if (_suspectHeader !== null) {
      const _body = _extractSectionBody(_suspectHeader);
      if (_body === "") {
        process.stderr.write(
          `[pi-enforcement:step-log-completeness] OBSERVE-ONLY: '## ${_suspectName} Section' has no real body — the role may have died mid-response. Claude Stop hook will block if applicable. Step log: ${activeLog}\n`,
        );
      }
    }
  });
}
