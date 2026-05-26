/**
 * static-site-build-check.ts — Pi enforcement: run static site build check
 * on developer session shutdown (SubagentStop equivalent).
 *
 * Mirrors: templates/shared/hooks/static-site-build-check.sh
 * Event: session_shutdown (SubagentStop equivalent)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parseAgentType, debugLog } from "../lib/hook-helpers";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "static-site-build-check",
  event: "session_shutdown",
  matcher: "developer-html|developer-hugo|developer-vite",
} as const;

const STATIC_DEV_AGENTS = new Set([
  "developer-html",
  "developer-hugo",
  "developer-vite",
]);

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    if (!STATIC_DEV_AGENTS.has(agentType)) return;

    const projectDir = process.env["CWD"] ?? process.cwd();
    debugLog("static-site-build-check", `agent=${agentType} cwd=${projectDir}`);

    if (!fs.existsSync(path.join(projectDir, "package.json"))) return;

    try {
      execSync("mise exec -- npm run build", {
        cwd: projectDir,
        stdio: "pipe",
      });
      debugLog("static-site-build-check", "build OK");
    } catch (err) {
      const output =
        (err as { stdout?: Buffer; stderr?: Buffer }).stdout?.toString() ?? "";
      const errOutput =
        (err as { stdout?: Buffer; stderr?: Buffer }).stderr?.toString() ?? "";
      debugLog("static-site-build-check", `build FAILED: ${errOutput}`);
      // Log to stderr for orchestrator visibility (Pi doesn't support decision:block in session_shutdown)
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] build FAILED:\n${output}\n${errOutput}\n`,
      );
    }
  });
}
