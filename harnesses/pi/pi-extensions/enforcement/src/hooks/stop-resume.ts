/**
 * stop-resume.ts — Pi enforcement: detect transient errors and log resume
 * suggestion (Stop equivalent).
 *
 * Mirrors: templates/shared/hooks/stop-resume.sh
 * Event: session_shutdown (Stop equivalent)
 *
 * Note: Pi extensions cannot auto-resume sessions. This module logs
 * a warning to stderr suggesting manual resume when transient errors detected.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "stop-resume",
  event: "session_shutdown",
  matcher: "*",
} as const;

export const TRANSIENT_ERROR_PATTERNS = [
  /Stream idle timeout/i,
  /Unable to connect/i,
  /FailedToOpenSocket/i,
  /ConnectionRefused/i,
  /API Error: 529/i,
  /API Error: 500/i,
  /API Error: 502/i,
  /API Error: 503/i,
  /API Error: 504/i,
  /overloaded_error/i,
  /Internal server error/i,
  /upstream connect error/i,
  /connection reset/i,
  /socket hang up/i,
  /ETIMEDOUT/i,
  /context deadline exceeded/i,
  /File has been modified since read/i,
  /has been unexpectedly modified/i,
  /socket connection was closed/i,
];

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async (event) => {
    debugLog("stop-resume", `reason=${event.reason}`);

    // Only relevant for quit (not reload/new/resume/fork)
    if (event.reason !== "quit") return;

    const lastMessage = process.env["LAST_ASSISTANT_MESSAGE"] ?? "";
    const isTransient = TRANSIENT_ERROR_PATTERNS.some((p) =>
      p.test(lastMessage),
    );

    if (isTransient) {
      process.stderr.write(
        "[pi-enforcement:stop-resume] Transient error detected — consider resuming with `pi --resume`\n",
      );
    }
  });
}
