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
import { execSync, execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

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

    let stagedFiles: string[];
    try {
      stagedFiles = execSync("git diff --cached --name-only", {
        encoding: "utf8",
      })
        .split("\n")
        .filter(Boolean);
    } catch {
      // git not available or not in repo — pass through
      return;
    }

    if (stagedFiles.length === 0) return;

    const stagedExs = stagedFiles.filter((f) => /\.exs?$/.test(f));
    if (stagedExs.length === 0) return;

    // execFileSync passes args as an array — no shell interpolation, so a
    // staged path containing a space (or shell metacharacter) cannot break
    // the command or silently fail-open the whole check.
    let exDiff: string;
    try {
      exDiff = execFileSync(
        "git",
        ["diff", "--cached", "--", ...stagedExs],
        { encoding: "utf8" },
      );
    } catch (e) {
      return deny(
        `BLOCKED by env-var-sample-consistency: 'git diff --cached' failed unexpectedly for staged Elixir files (${(e as Error).message}). Cannot verify .env.sample parity — resolve the git error before committing.`,
      );
    }

    // Only ADDED lines (starting with "+") with a string-literal arg count —
    // argless reads like `System.get_env()` give no name to look up in
    // .env.sample, so they cannot be a documentation gap.
    const literalArgRe = /System\.(get_env|fetch_env)\(\s*"[^"]+"/;
    const addedEnvLines = exDiff
      .split("\n")
      .filter((l) => l.startsWith("+") && literalArgRe.test(l));

    if (addedEnvLines.length === 0) return;

    // Extract each quoted literal var name from the added lines.
    const addedNames = addedEnvLines
      .map((l) => l.match(literalArgRe)?.[0].match(/"([^"]+)"/)?.[1])
      .filter((n): n is string => Boolean(n));

    if (addedNames.length === 0) return;

    // Read the working-tree .env.sample. ENOENT (file absent) means every
    // extracted name is "not declared" — loud, not swallowed; any other read
    // error propagates (not caught here).
    let sampleContent = "";
    try {
      sampleContent = readFileSync(".env.sample", "utf8");
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
    }

    const isDeclared = (name: string): boolean =>
      new RegExp(`^(export )?${name}=`, "m").test(sampleContent);

    const undocumented = addedNames.filter((n) => !isDeclared(n));

    if (undocumented.length === 0) return;

    const sampleStaged = stagedFiles.some((f) =>
      [".env.sample", ".env.prod.sample"].includes(f),
    );

    if (!sampleStaged) {
      return deny(
        "BLOCKED by env-var-sample-consistency: staged Elixir files add System.get_env/fetch_env calls, but .env.sample and .env.prod.sample are not staged. Stage the sample files with the new env var.",
      );
    }
  });
}
