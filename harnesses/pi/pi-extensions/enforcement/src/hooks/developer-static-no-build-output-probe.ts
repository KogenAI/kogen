/**
 * developer-static-no-build-output-probe.ts — Pi enforcement: developer-static may not probe build-output dirs (public/, dist/) via Read/Grep/Glob.
 *
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: Read|Grep|Glob
 *
 * GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
 * Edit registry.yaml and run `make install` to regenerate.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, repoRelative } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "developer-static-no-build-output-probe",
  event: "tool_call",
  matcher: "read|grep|glob",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (!(event.toolName === "read" || event.toolName === "grep" || event.toolName === "glob")) return;

    const agentType = process.env["AGENT_TYPE"] ?? "";
    if (!(agentType === "developer-static")) return;

    const input = event.input as { file_path?: string; path?: string };
    const filePath: string = input.file_path ?? input.path ?? "";
    debugLog("developer-static-no-build-output-probe", `file=${filePath}`);

    const rel = repoRelative(filePath);
    if (/(^|\/)public\/|(^|\/)dist\//.test(rel)) {
      return deny(
        "BLOCKED by developer-static-no-build-output-probe: do not read/grep/glob generated build output (public/, dist/). Inspect SOURCE files; the gate verifies build output automatically.: " + filePath,
      );
    }
  });
}
