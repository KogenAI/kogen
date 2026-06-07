/**
 * committer-write-allowlist.ts — Pi enforcement: committer may only edit canonical session log files (allowlist).
 *
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: Write|Edit
 *
 * GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
 * Edit registry.yaml and run `make install` to regenerate.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, repoRelative } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "committer-write-allowlist",
  event: "tool_call",
  matcher: "write|edit",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (!(event.toolName === "write" || event.toolName === "edit")) return;

    const agentType = process.env["AGENT_TYPE"] ?? "";
    if (!(agentType === "committer")) return;

    const filePath: string = (event.input as { file_path?: string }).file_path ?? "";
    debugLog("committer-write-allowlist", `file=${filePath}`);

    const rel = repoRelative(filePath);
    if (/codegen\/logging\/[0-9]{8}_[0-9]{6}(_[a-z0-9-]+)?_(session|step[0-9]+_[a-z0-9-]+)\.md$/.test(rel)) {
      return;
    }

    return deny(
      "BLOCKED by committer-write-allowlist: committer may only write to canonical session logs: " + filePath,
    );
  });
}
