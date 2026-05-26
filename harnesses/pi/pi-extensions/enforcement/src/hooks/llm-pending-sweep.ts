/**
 * llm-pending-sweep.ts — Pi enforcement: sweep stale LLM-pending flag files
 * on session shutdown (Stop equivalent).
 *
 * Mirrors: templates/shared/hooks/llm-pending-sweep.sh
 * Event: session_shutdown (Stop equivalent)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "llm-pending-sweep",
  event: "session_shutdown",
  matcher: "*",
} as const;

const MAX_AGE_MS = 120 * 60 * 1000; // 120 minutes

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const cwd = process.env["CWD"] ?? process.cwd();
    const flagDir = path.join(cwd, "codegen", "llm-pending");
    debugLog("llm-pending-sweep", `flagDir=${flagDir}`);

    if (!fs.existsSync(flagDir)) return;

    const now = Date.now();
    try {
      const files = fs.readdirSync(flagDir).filter((f) => f.endsWith(".flag"));
      for (const file of files) {
        const filePath = path.join(flagDir, file);
        const stat = fs.statSync(filePath);
        if (now - stat.mtimeMs > MAX_AGE_MS) {
          fs.rmSync(filePath, { force: true });
          debugLog("llm-pending-sweep", `removed stale flag: ${filePath}`);
        }
      }
    } catch {
      // Non-fatal sweep failure
    }
  });
}
