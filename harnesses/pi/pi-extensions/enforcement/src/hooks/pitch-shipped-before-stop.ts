/**
 * pitch-shipped-before-stop.ts — Pi enforcement: warn when pitch is still in
 * ready/ after commit (auto-ship mirror).
 *
 * Mirrors: harnesses/claude/hooks/pitch-shipped-before-stop.sh
 * Event: session_shutdown (Stop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * Bypass paths:
 *   process.env.CLAUDE_ROLE === "dashboard-build" — dashboard manages shipped/ move
 *   process.env.PI_ROLE === "dashboard-build"     — same, Pi harness
 *   process.env.CODEGEN_NO_AUTOSHIP               — explicit operator suppression
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

export const HANDLER_META = {
  name: "pitch-shipped-before-stop",
  event: "session_shutdown",
  matcher: "*",
} as const;

/** Find the most recently modified step log in codegen/logging/. */
function getActiveStepLog(projectDir: string): string | null {
  const loggingDir = path.join(projectDir, "codegen", "logging");
  if (!fs.existsSync(loggingDir)) return null;

  const logFiles = fs
    .readdirSync(loggingDir)
    .filter((f) => f.endsWith(".md") && !f.includes("progress"))
    .map((f) => ({
      name: f,
      mtime: fs.statSync(path.join(loggingDir, f)).mtimeMs,
    }))
    .sort((a, b) => b.mtime - a.mtime);

  if (logFiles.length === 0) return null;
  return path.join(loggingDir, logFiles[0].name);
}

/** Find the most recently modified pitch in codegen/pitches/. */
function getActivePitch(projectDir: string): string | null {
  const pitchesDir = path.join(projectDir, "codegen", "pitches");
  if (!fs.existsSync(pitchesDir)) return null;

  // Search ready/ and shipped/ for recently modified pitches
  const allPitches: { fullPath: string; mtime: number }[] = [];
  for (const sub of ["ready", "shipped", "draft"]) {
    const subDir = path.join(pitchesDir, sub);
    if (!fs.existsSync(subDir)) continue;
    for (const f of fs.readdirSync(subDir)) {
      if (!f.endsWith(".md")) continue;
      const fullPath = path.join(subDir, f);
      allPitches.push({ fullPath, mtime: fs.statSync(fullPath).mtimeMs });
    }
  }

  if (allPitches.length === 0) return null;
  allPitches.sort((a, b) => b.mtime - a.mtime);
  return allPitches[0].fullPath;
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

    // Role bypass — dashboard-build or explicit env suppression.
    const claudeRole = process.env["CLAUDE_ROLE"] ?? "";
    const piRole = process.env["PI_ROLE"] ?? "";
    const activeRole = claudeRole || piRole;
    if (
      activeRole === "dashboard-build" ||
      process.env["CODEGEN_NO_AUTOSHIP"]
    ) {
      debugLog(
        "pitch-shipped-before-stop",
        `skip: role-bypass role=${activeRole}`,
      );
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

    // Only act after committer has committed.
    if (!logContent.includes("## committer Section")) {
      debugLog("pitch-shipped-before-stop", "skip: committer section absent");
      return;
    }

    // Check if any pitch is in ready/.
    const readyDir = path.join(projectDir, "codegen", "pitches", "ready");
    if (!fs.existsSync(readyDir)) {
      debugLog("pitch-shipped-before-stop", "skip: no ready/ dir");
      return;
    }

    const readyPitches = fs
      .readdirSync(readyDir)
      .filter((f) => f.endsWith(".md"));

    if (readyPitches.length === 0) {
      debugLog("pitch-shipped-before-stop", "skip: no pitches in ready/");
      return;
    }

    // Use the most recently modified pitch in ready/ as the active one.
    const activePitch = readyPitches
      .map((f) => ({
        name: f,
        mtime: fs.statSync(path.join(readyDir, f)).mtimeMs,
      }))
      .sort((a, b) => b.mtime - a.mtime)[0].name;

    count += 1;
    fs.writeFileSync(counterFile, String(count));

    process.stderr.write(
      `[pi-enforcement:pitch-shipped-before-stop] WARNING: Pitch ${activePitch} was committed but is still in codegen/pitches/ready/. Move it to shipped/: mv codegen/pitches/ready/${activePitch} codegen/pitches/shipped/${activePitch} (plain mv, NEVER git mv). Count: ${count}\n`,
    );
  });
}
