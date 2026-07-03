/**
 * env-var-sample-consistency.ts — Pi enforcement: block git commits that add
 * System.get_env without updating .env.sample.
 *
 * Mirrors: templates/shared/hooks/env-var-sample-consistency.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  deny,
  parseAgentType,
  debugLog,
  isCodegenLogWrite,
} from "../lib/hook-helpers";
import { execSync } from "node:child_process";

export const HANDLER_META = {
  name: "env-var-sample-consistency",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    if (parseAgentType() !== "committer") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("env-var-sample-consistency", `cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match or
    // counter increment.
    if (isCodegenLogWrite(command)) return;

    if (!/\bgit\s+commit\b/.test(command)) return;

    try {
      const stagedFiles = execSync("git diff --cached --name-only", {
        encoding: "utf8",
      })
        .split("\n")
        .filter(Boolean);

      if (stagedFiles.length === 0) return;

      const stagedExs = stagedFiles.filter((f) => /\.exs?$/.test(f));
      if (stagedExs.length === 0) return;

      const exDiff = execSync(`git diff --cached -- ${stagedExs.join(" ")}`, {
        encoding: "utf8",
      });

      if (
        !/(System\.get_env|System\.fetch_env)/.test(exDiff) ||
        !/^\+/.test(exDiff)
      ) {
        return;
      }

      // Check if new System.get_env calls were added (lines starting with +)
      const addedEnvLines = exDiff
        .split("\n")
        .filter(
          (l) =>
            l.startsWith("+") && /(System\.get_env|System\.fetch_env)/.test(l),
        );

      if (addedEnvLines.length === 0) return;

      const sampleStaged = stagedFiles.some((f) =>
        [".env.sample", ".env.prod.sample"].includes(f),
      );

      if (!sampleStaged) {
        return deny(
          "BLOCKED by env-var-sample-consistency: staged Elixir files add System.get_env/fetch_env calls, but .env.sample and .env.prod.sample are not staged. Stage the sample files with the new env var.",
        );
      }
    } catch {
      // git not available or not in repo — pass through
    }
  });
}
