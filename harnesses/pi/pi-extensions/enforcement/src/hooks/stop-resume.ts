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

const TRANSIENT_ERROR_PATTERNS = [
  /stream idle/i,
  /connection refused/i,
  /502\s*bad gateway/i,
  /529\s*overloaded/i,
  /ECONNRESET/i,
  /ETIMEDOUT/i,
  /network.*error/i,
  /file has been modified since read/i,
  /has been unexpectedly modified/i,
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
