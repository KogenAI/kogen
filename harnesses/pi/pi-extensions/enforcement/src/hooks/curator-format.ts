/**
 * curator-format.ts — Pi enforcement: run `make format` after context-curator
 * session shutdown so curator-authored markdown is formatted before committer
 * stages it.
 *
 * Mirrors: harnesses/claude/hooks/curator-format.sh
 * Event: session_shutdown (SubagentStop equivalent)
 *
 * Observe-only: Pi session_shutdown cannot block; this hook is a fix-up, not
 * a gate. Always returns without blocking.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parseAgentType, debugLog } from "../lib/hook-helpers";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "curator-format",
  event: "session_shutdown",
  matcher: "context-curator",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    if (agentType !== "context-curator") return;

    const projectDir = process.env["CWD"] ?? process.cwd();
    debugLog("curator-format", `agent=${agentType} cwd=${projectDir}`);

    try {
      process.chdir(projectDir);
    } catch {
      return;
    }

    // Run make format only if a Makefile with a `format:` target exists.
    const makefilePath = path.join(projectDir, "Makefile");
    if (fs.existsSync(makefilePath)) {
      const makefileContent = fs.readFileSync(makefilePath, "utf8");
      if (!makefileContent.match(/^format:/m)) {
        debugLog("curator-format", "no format: target in Makefile — skipping");
        return;
      }
      try {
        execSync("make format", { cwd: projectDir, stdio: "ignore" });
        debugLog("curator-format", "make format ran");
      } catch {
        // Non-fatal — fix-up hook, never blocks.
        debugLog("curator-format", "make format had errors (non-fatal)");
      }
    } else {
      debugLog("curator-format", "no Makefile — skipping");
    }
  });
}
