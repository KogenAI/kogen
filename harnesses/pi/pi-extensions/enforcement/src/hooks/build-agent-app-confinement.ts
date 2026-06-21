/**
 * build-agent-app-confinement.ts — Pi enforcement twin of
 * build-agent-app-confinement.sh.
 *
 * Denies write/edit/multiEdit when CODEGEN_BUILD_CWD is set and the target
 * file resolves outside that dir. Full-fidelity port (needs only the
 * CODEGEN_BUILD_CWD env var + tool input path — both available in Pi).
 *
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: write|edit|multiEdit
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as path from "node:path";
import { deny, debugLog, resolveRealPath } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "build-agent-app-confinement",
  event: "tool_call",
  matcher: "write|edit|multiEdit",
} as const;

const SCOPED_TOOLS = new Set(["write", "edit", "multiEdit"]);

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (!SCOPED_TOOLS.has(event.toolName)) return;

    const buildCwd = process.env["CODEGEN_BUILD_CWD"] ?? "";
    if (!buildCwd) return; // inert outside a managed build

    const filePath: string =
      (event.input as { path?: string; file_path?: string }).path ??
      (event.input as { path?: string; file_path?: string }).file_path ??
      "";
    if (!filePath) return;

    // Scratch escape hatch.
    if (filePath.startsWith("/tmp/") || filePath.startsWith("/private/tmp/")) {
      return;
    }

    const canonCwd = resolveRealPath(buildCwd);
    // Resolve relative paths against the build cwd (dispatch execs with
    // cwd == CODEGEN_BUILD_CWD during a build).
    const absFile = path.isAbsolute(filePath)
      ? filePath
      : path.join(canonCwd, filePath);
    const canonFile = resolveRealPath(absFile);

    debugLog(
      "build-agent-app-confinement",
      `tool=${event.toolName} cwd=${canonCwd} file=${canonFile}`,
    );

    if (canonFile === canonCwd) return;
    const cwdPrefix = canonCwd.endsWith("/") ? canonCwd : canonCwd + "/";
    if (canonFile.startsWith(cwdPrefix)) return;

    return deny(
      `BLOCKED by build-agent-app-confinement: managed build agents may only write inside the app sandbox (${canonCwd}). Got: ${canonFile} (outside CODEGEN_BUILD_CWD).`,
    );
  });
}
