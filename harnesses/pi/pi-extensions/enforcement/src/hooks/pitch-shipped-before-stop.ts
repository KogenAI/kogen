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
import { debugLog, getActiveStepLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

export const HANDLER_META = {
  name: "pitch-shipped-before-stop",
  event: "session_shutdown",
  matcher: "*",
} as const;

/** Extract pitch slug from a session log filename: <ts>_<slug>_session.md → slug. */
function slugFromLogName(logPath: string): string | null {
  const basename = path.basename(logPath);
  const match = /^[0-9]{8}_[0-9]{6}_(.+)_session\.md$/.exec(basename);
  if (!match) return null;
  return match[1];
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

    // Extract slug from log filename: <ts>_<slug>_session.md → slug.
    const slug = slugFromLogName(logPath);
    if (!slug) {
      debugLog(
        "pitch-shipped-before-stop",
        "skip: no slug in log filename (free-form or multi-step log)",
      );
      return;
    }

    debugLog(
      "pitch-shipped-before-stop",
      `slug=${slug} log=${path.basename(logPath)}`,
    );

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
