/**
 * committer-gate-verdict-clear.ts — Pi enforcement: deny a git commit from
 * the committer agent unless codegen/gate-pending/gate-result.json exists
 * and its .verdict field is "clear".
 *
 * Mirrors: harnesses/claude/hooks/committer-gate-verdict-clear.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * The committer's own rule (shared/rules/roles/committer.md) says: read the
 * .verdict field of codegen/gate-pending/gate-result.json; absent or
 * non-clear → do not commit. This hook makes that structural rather than an
 * unenforced instruction. Verdict-only — no freshness/base_sha check here.
 *
 * projectDir anchors to the commit's target repo root via git-toplevel
 * (repoRoot), falling back to the raw payload dir when it is not inside a
 * git repo. This prevents a false "is missing" deny when the payload cwd is
 * a subdir of the repo the loop wrote gate-result.json to. Denies name both
 * the resolved and raw dirs for diagnosability.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  deny,
  parseAgentType,
  debugLog,
  isCodegenLogWrite,
  getGateVerdict,
  repoRoot,
} from "../lib/hook-helpers";
import * as fs from "fs";
import * as path from "path";

export const HANDLER_META = {
  name: "committer-gate-verdict-clear",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    if (parseAgentType() !== "committer") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("committer-gate-verdict-clear", `cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match.
    if (isCodegenLogWrite(command)) return;

    if (!/\bgit\s+commit(?:[\s;&|]|$)/.test(command)) return;

    const rawDir =
      process.env["CLAUDE_PROJECT_DIR"] ??
      process.env["CWD"] ??
      process.cwd();
    const projectDir = repoRoot(rawDir);

    const resultFile = path.join(
      projectDir,
      "codegen",
      "gate-pending",
      "gate-result.json",
    );
    if (!fs.existsSync(resultFile)) {
      return deny(
        `BLOCKED by committer-gate-verdict-clear: codegen/gate-pending/gate-result.json is missing at ${projectDir} (resolved from ${rawDir}). The gate verdict cannot be confirmed. Do not commit until a gate run has produced a clear verdict.`,
      );
    }

    const verdict = getGateVerdict(projectDir);

    if (verdict !== "clear") {
      return deny(
        `BLOCKED by committer-gate-verdict-clear: gate-result.json at ${projectDir} (resolved from ${rawDir}) verdict is '${verdict || "absent"}' (need 'clear'). Do not commit — the build has not reached a clear gate verdict.`,
      );
    }

    debugLog("committer-gate-verdict-clear", "allow: verdict=clear");
  });
}
