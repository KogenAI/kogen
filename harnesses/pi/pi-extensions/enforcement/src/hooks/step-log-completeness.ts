/**
 * step-log-completeness.ts — Pi enforcement: warn if session shuts down with
 * incomplete delegation cycle (Stop equivalent).
 *
 * Mirrors: templates/shared/hooks/step-log-completeness.sh
 * Event: session_shutdown (Stop equivalent)
 *
 * Note: In Pi, session_shutdown cannot block. This logs a warning to stderr.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "step-log-completeness",
  event: "session_shutdown",
  matcher: "*",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
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

    const logContent = fs.readFileSync(activeLog, "utf8");

    if (logContent.includes("INCONCLUSIVE ⚠️")) return;

    const hasDeveloper = /## developer.*Section/i.test(logContent);
    const hasAllClear = /ALL CLEAR ✅/.test(logContent);
    const hasReviewer = /## reviewer.*Section/i.test(logContent);
    const hasCurator = /## context-curator.*Section/i.test(logContent);
    const hasCommitter = /## committer.*Section/i.test(logContent);

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
  });
}
