/**
 * stop-cycle-guard.ts — Pi enforcement: guard against mid-cycle session
 * shutdown (Stop equivalent).
 *
 * Mirrors: harnesses/claude/hooks/stop-cycle-guard.sh
 * Event: session_shutdown (Stop equivalent)
 *
 * Note: In Pi, session_shutdown cannot block the session from ending.
 * This module logs a warning when the cycle appears incomplete.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

export const HANDLER_META = {
  name: "stop-cycle-guard",
  event: "session_shutdown",
  matcher: "*",
} as const;

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

    const sessionId = process.env["SESSION_ID"] ?? "unknown";
    const projectDir = process.env["CWD"] ?? process.cwd();
    const counterFile = path.join(
      os.tmpdir(),
      `claude-cycle-guard-${sessionId}.count`,
    );

    debugLog("stop-cycle-guard", `session=${sessionId}`);

    // Resolve active step log first (mtime-sorted) — mirrors bash hoist of
    // session_log_from_transcript above the counter read.
    const loggingDir = path.join(projectDir, "codegen", "logging");
    let logFiles: { name: string; mtime: number }[] = [];
    if (fs.existsSync(loggingDir)) {
      logFiles = fs
        .readdirSync(loggingDir)
        .filter((f) => f.endsWith(".md") && !f.includes("progress"))
        .map((f) => ({
          name: f,
          mtime: fs.statSync(path.join(loggingDir, f)).mtimeMs,
        }))
        .sort((a, b) => b.mtime - a.mtime);
    }
    // stepKey: basename of the most-recent log, or "" when loggingDir absent/empty.
    // Empty stepKey = keep current scope (do NOT reset counter).
    const stepKey = logFiles.length > 0 ? logFiles[0].name : "";

    // Read per-step counter (self-describing: line 1 = step-log scope, line 2 = count).
    let prevStep = "";
    let count = 0;
    try {
      const raw = fs.readFileSync(counterFile, "utf8").split("\n");
      prevStep = raw[0] ?? "";
      count = parseInt((raw[1] ?? "").trim(), 10) || 0;
    } catch {
      count = 0;
    }

    // Forward progress to a NEW step resets the budget. Empty stepKey = keep scope.
    if (stepKey && stepKey !== prevStep) {
      count = 0;
    }
    const scopeStep = stepKey || prevStep;

    if (count >= 2) {
      process.stderr.write(
        `[pi-enforcement:stop-cycle-guard] per-step retry cap reached for step ${scopeStep || "unknown"} (count=${count}) — allowing stop\n`,
      );
      fs.rmSync(counterFile, { force: true });
      return;
    }

    // Check for in-flight gate (latest.flag with live PID)
    const flagPath = path.join(
      projectDir,
      "codegen",
      "gate-pending",
      "latest.flag",
    );
    if (fs.existsSync(flagPath)) {
      try {
        const flagContent = fs.readFileSync(flagPath, "utf8");
        const pidMatch = flagContent.match(/^pid=(\d+)/m);
        const gateMatch = flagContent.match(/^gate=(.+)/m);
        if (pidMatch) {
          const pid = parseInt(pidMatch[1], 10);
          const gateCmd = gateMatch ? gateMatch[1].trim() : "unknown";
          // Check if PID is alive
          try {
            process.kill(pid, 0); // throws if dead
            // PID is alive — gate in flight
            count += 1;
            fs.writeFileSync(counterFile, `${scopeStep}\n${count}\n`);
            process.stderr.write(
              `[pi-enforcement:stop-cycle-guard] WARNING: An in-flight gate (PID ${pid}, gate '${gateCmd}') has not produced a verdict. You MUST NOT end your turn while a gate runs. Count: ${count}\n`,
            );
            return;
          } catch {
            // PID dead — sweep flag
            try {
              fs.rmSync(flagPath, { force: true });
            } catch {
              // ignore cleanup errors
            }
          }
        }
      } catch {
        // flag read error — ignore
      }
    }

    // No active log — nothing to check (loggingDir absent or empty).
    if (logFiles.length === 0) return;

    // Check if cycle is incomplete (developer done but no committer)
    const activeLog = path.join(loggingDir, logFiles[0].name);
    const logContent = fs.readFileSync(activeLog, "utf8");

    const hasDeveloper = /## developer.*Section/i.test(logContent);
    const hasVeVerdict = /ALL CLEAR ✅|FAILED ❌|INCONCLUSIVE ⚠️/.test(
      logContent,
    );
    const hasReviewer = /## reviewer.*Section/i.test(logContent);
    const hasCurator = /## context-curator.*Section/i.test(logContent);
    const hasCommitter = /## committer.*Section/i.test(logContent);

    // Hardening #1 (advisory): developer section present but no VE verdict
    // and no gate-result.json → VE likely never ran (mirrors stop-cycle-guard.sh).
    const gateResultPath = path.join(
      projectDir,
      "codegen",
      "gate-pending",
      "gate-result.json",
    );
    const hasGateResult = fs.existsSync(gateResultPath);
    if (hasDeveloper && !hasVeVerdict && !hasGateResult && !hasReviewer) {
      count += 1;
      fs.writeFileSync(counterFile, `${scopeStep}\n${count}\n`);
      process.stderr.write(
        `[pi-enforcement:stop-cycle-guard] WARNING: developer ran but gate never produced a verdict (no emoji in log, no gate-result.json). VE likely never ran. Count: ${count}\n`,
      );
      return;
    }

    if (
      (hasDeveloper && hasVeVerdict && !hasReviewer) ||
      (hasReviewer && !hasCurator) ||
      (hasReviewer && hasCurator && !hasCommitter)
    ) {
      count += 1;
      fs.writeFileSync(counterFile, `${scopeStep}\n${count}\n`);
      process.stderr.write(
        `[pi-enforcement:stop-cycle-guard] WARNING: mid-cycle stop detected — reviewer/context-curator/committer not yet run. Count: ${count}\n`,
      );
    } else {
      fs.rmSync(counterFile, { force: true });
    }
  });
}
