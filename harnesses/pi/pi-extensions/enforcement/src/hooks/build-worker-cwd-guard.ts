/**
 * build-worker-cwd-guard.ts — Pi enforcement: enforce build worker cwd
 * confinement.
 *
 * Mirrors: templates/shared/hooks/build-worker-cwd-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash, write, edit, read
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, isSubagent, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "build-worker-cwd-guard",
  event: "tool_call",
  matcher: "bash|write|edit|read",
} as const;

const ALLOWED_TOOLS = new Set(["bash", "write", "edit", "read"]);

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (!ALLOWED_TOOLS.has(event.toolName)) return;

    // Subagents pass through
    if (isSubagent()) return;

    const projectDir =
      process.env["CWD"] ?? process.env["PI_PROJECT_DIR"] ?? process.cwd();

    // Platform-repo bypass: test apps, production apps, local dev apps
    if (
      /\/.combobulate_test_apps\/.*\/apps\//.test(projectDir) ||
      /^\/home\/combobulate\/apps\//.test(projectDir) ||
      /\/AppBuilder\/apps\//.test(projectDir)
    ) {
      // Within a user app workspace — enforcement active
    } else {
      // Not a user-app workspace — pass through
      return;
    }

    debugLog(
      "build-worker-cwd-guard",
      `tool=${event.toolName} projectDir=${projectDir}`,
    );

    if (event.toolName === "bash") {
      const command: string =
        (event.input as { command?: string }).command ?? "";
      // Block absolute paths outside project dir
      const absPathMatch = command.match(/\/[^\s'"]+/g);
      if (absPathMatch) {
        for (const p of absPathMatch) {
          if (
            !p.startsWith(projectDir) &&
            !p.startsWith("/tmp") &&
            !p.startsWith("/dev")
          ) {
            return deny(
              `BLOCKED by build-worker-cwd-guard: Bash command references path outside workspace: ${p}`,
            );
          }
        }
      }
    } else {
      // write / edit / read — check file path
      const filePath: string =
        (event.input as { path?: string; file_path?: string }).path ??
        (event.input as { path?: string; file_path?: string }).file_path ??
        "";
      if (
        filePath &&
        !filePath.startsWith(projectDir) &&
        !filePath.startsWith("/tmp")
      ) {
        return deny(
          `BLOCKED by build-worker-cwd-guard: ${event.toolName} path outside workspace: ${filePath}`,
        );
      }
    }
  });
}
