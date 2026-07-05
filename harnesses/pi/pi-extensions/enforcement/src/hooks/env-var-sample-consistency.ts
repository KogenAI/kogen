/**
 * env-var-sample-consistency.ts — Pi enforcement: warn when the working-tree
 * diff (vs HEAD), scoped to *.ex/*.exs files, adds System.get_env/fetch_env
 * without updating .env.sample and .env.prod.sample.
 *
 * Mirrors: harnesses/claude/hooks/env-var-sample-consistency.sh
 * Event: session_shutdown (SubagentStop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * Relocated from a committer tool_call (PreToolUse) gate — the committer
 * cannot edit .env.sample, so gating there was a structural deadlock — to
 * developer session_shutdown, scanning the working-tree diff instead of the
 * staged-only diff. Scoped to *.ex/*.exs (not the whole tree) so a
 * test-authoring file's string literals (e.g. a fixture that writes
 * `System.get_env("X")` into a temp .exs file) never trip this hook.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog, parseAgentType } from "../lib/hook-helpers";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "env-var-sample-consistency",
  event: "session_shutdown",
  matcher: "developer-phoenix-backend|developer-phoenix-frontend",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    if (
      agentType !== "developer-phoenix-backend" &&
      agentType !== "developer-phoenix-frontend"
    ) {
      return;
    }

    const projectDir = process.env["CWD"] ?? process.cwd();
    debugLog("env-var-sample-consistency", `cwd=${projectDir}`);

    // Scope to *.ex/*.exs files only — prevents false positives from
    // test-authoring files (.ts/.sh) whose string literals merely construct
    // fixture text containing the same call-site pattern.
    let changedNames: string[];
    try {
      changedNames = execFileSync("git", ["diff", "HEAD", "--name-only"], {
        cwd: projectDir,
        encoding: "utf8",
      })
        .split("\n")
        .filter((f) => /\.exs?$/.test(f));
    } catch {
      process.stderr.write(
        "[pi-enforcement:env-var-sample-consistency] WARNING: git diff HEAD failed — cannot verify env-sample parity.\n",
      );
      return;
    }

    if (changedNames.length === 0) return;

    let wtDiff: string;
    try {
      wtDiff = execFileSync(
        "git",
        ["diff", "HEAD", "--", ...changedNames],
        { cwd: projectDir, encoding: "utf8" },
      );
    } catch {
      process.stderr.write(
        "[pi-enforcement:env-var-sample-consistency] WARNING: git diff HEAD failed — cannot verify env-sample parity.\n",
      );
      return;
    }

    if (!wtDiff) return;

    // Only ADDED lines (starting with "+") with a string-literal arg count —
    // argless reads like `System.get_env()` give no name to look up in
    // .env.sample, so they cannot be a documentation gap.
    const literalArgRe = /System\.(get_env|fetch_env)\(\s*"[^"]+"/;
    const addedEnvLines = wtDiff
      .split("\n")
      .filter((l) => l.startsWith("+") && literalArgRe.test(l));

    if (addedEnvLines.length === 0) return;

    // Extract each quoted literal var name from the added lines.
    const addedNames = addedEnvLines
      .map((l) => l.match(literalArgRe)?.[0].match(/"([^"]+)"/)?.[1])
      .filter((n): n is string => Boolean(n));

    if (addedNames.length === 0) return;

    // Read the working-tree sample files. ENOENT (file absent) means every
    // extracted name is "not declared" — loud, not swallowed; any other read
    // error propagates (not caught here).
    const readSample = (fileName: string): string => {
      try {
        return readFileSync(path.join(projectDir, fileName), "utf8");
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
        return "";
      }
    };

    const sampleContent = readSample(".env.sample");
    const prodSampleContent = readSample(".env.prod.sample");

    const isDeclared = (name: string, content: string): boolean =>
      new RegExp(`^(export )?${name}=`, "m").test(content);

    const undocumented = addedNames.filter(
      (n) =>
        !isDeclared(n, sampleContent) || !isDeclared(n, prodSampleContent),
    );

    if (undocumented.length === 0) return;

    process.stderr.write(
      `[pi-enforcement:env-var-sample-consistency] WARNING: new env var '${undocumented[0]}' read (System.get_env/fetch_env) but not declared in .env.sample/.env.prod.sample. Add it to both sample files.\n`,
    );
  });
}
