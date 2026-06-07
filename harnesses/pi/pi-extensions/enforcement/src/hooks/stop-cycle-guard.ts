/**
 * stop-cycle-guard.ts — Pi enforcement: guard against mid-cycle session
 * shutdown (Stop equivalent).
 *
 * Mirrors: templates/shared/hooks/stop-cycle-guard.sh
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

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const sessionId = process.env["SESSION_ID"] ?? "unknown";
    const projectDir = process.env["CWD"] ?? process.cwd();
    const counterFile = path.join(
      os.tmpdir(),
      `claude-cycle-guard-${sessionId}.count`,
    );

    debugLog("stop-cycle-guard", `session=${sessionId}`);

    // Read counter
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
            fs.writeFileSync(counterFile, String(count));
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

    // Find active step log
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

    // Check if cycle is incomplete (developer done but no committer)
    const activeLog = path.join(loggingDir, logFiles[0].name);
    const logContent = fs.readFileSync(activeLog, "utf8");

    const hasDeveloper = /## developer.*Section/i.test(logContent);
    const hasAllClear = /ALL CLEAR ✅/.test(logContent);
    const hasReviewer = /## reviewer.*Section/i.test(logContent);
    const hasCurator = /## context-curator.*Section/i.test(logContent);
    const hasCommitter = /## committer.*Section/i.test(logContent);

    if (
      (hasDeveloper && hasAllClear && !hasReviewer) ||
      (hasReviewer && !hasCurator) ||
      (hasReviewer && hasCurator && !hasCommitter)
    ) {
      count += 1;
      fs.writeFileSync(counterFile, String(count));
      process.stderr.write(
        `[pi-enforcement:stop-cycle-guard] WARNING: mid-cycle stop detected — reviewer/context-curator/committer not yet run. Count: ${count}\n`,
      );
    } else {
      fs.rmSync(counterFile, { force: true });
    }
  });
}
