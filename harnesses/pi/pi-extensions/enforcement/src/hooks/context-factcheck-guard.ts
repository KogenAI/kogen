/**
 * context-factcheck-guard.ts — Pi enforcement: block git commits when staged
 * orientation docs contain named-path claims that don't resolve or
 * <!-- count: CMD -->NNN anchors whose live probe mismatches NNN.
 *
 * Mirrors: harnesses/claude/hooks/context-factcheck-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * Full-fidelity: reads staged blobs via git show, no transcript dependency.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "context-factcheck-guard",
  event: "tool_call",
  matcher: "bash",
} as const;

const ALLOWED_VERBS = new Set([
  "ls",
  "grep",
  "wc",
  "find",
  "cat",
  "sort",
  "uniq",
  "head",
  "tail",
]);

const INJECTION_RE = /\$\(|`|>|;|&&|&/;

function isAllowedVerb(verb: string): boolean {
  return ALLOWED_VERBS.has(verb);
}

function extractNamedPaths(line: string): string[] {
  const re =
    /`([a-zA-Z0-9_-]+\/[a-zA-Z0-9_./-]+\.(?:sh|md|py|ts|js|json|yaml|exs|ex))`/g;
  const results: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(line)) !== null) {
    results.push(m[1]);
  }
  return results;
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string = (event.input as { command?: string }).command ?? "";
    if (!/(^|[\s;&|])git\s+commit\b/.test(command)) return;

    debugLog("context-factcheck-guard", `cmd=${command}`);

    try {
      const cwd = process.cwd();

      // Detect layout.
      let layout: "platform" | "userapp" | null = null;
      if (fs.existsSync(path.join(cwd, "PROJECT_CONTEXT.md"))) {
        layout = "platform";
      } else if (
        fs.existsSync(path.join(cwd, "codegen", "PROJECT_CONTEXT.md"))
      ) {
        layout = "userapp";
      }
      if (!layout) return;

      // Find staged orientation docs.
      const stagedAll = execSync("git diff --cached --name-only", {
        encoding: "utf8",
      })
        .split("\n")
        .filter(Boolean);

      const orientationRe =
        /^(CLAUDE\.md|AGENTS\.md|PROJECT_CONTEXT\.md|codegen\/PROJECT_CONTEXT\.md|context\/[^/]+\.md)$/;
      const stagedDocs = stagedAll.filter((f) => orientationRe.test(f));

      if (stagedDocs.length === 0) return;

      const violations: string[] = [];

      for (const docPath of stagedDocs) {
        let blob: string;
        try {
          blob = execSync(`git show :${docPath}`, {
            encoding: "utf8",
          });
        } catch {
          continue;
        }

        const lines = blob.split("\n");
        for (let i = 0; i < lines.length; i++) {
          const line = lines[i];
          const linenum = i + 1;

          // ── Claim class 1: named-path probes ──────────────────────────────
          const namedPaths = extractNamedPaths(line);
          for (const claimPath of namedPaths) {
            if (!fs.existsSync(path.join(cwd, claimPath))) {
              violations.push(
                `context-factcheck-guard: ${docPath}:${linenum} references \`${claimPath}\` which does not exist. Fix the path or remove the claim.`,
              );
            }
          }

          // ── Claim class 2: count-anchor probes ────────────────────────────
          // Match: <!-- count: CMD -->NNN  (digits immediately after -->)
          if (/<!--\s*count:\s*.+-->[0-9]+/.test(line)) {
            // Extract CMD.
            const cmdMatch = line.match(
              /<!--\s*count:\s*(.*?)-->[0-9]/,
            );
            const anchorCmd = cmdMatch ? cmdMatch[1].trimEnd() : "";

            // Extract NNN.
            const nnnMatch = line.match(/-->([0-9]+)/);
            const anchorNnn = nnnMatch ? nnnMatch[1] : "";

            if (!anchorNnn || !/^[0-9]+$/.test(anchorNnn)) {
              violations.push(
                `context-factcheck-guard: ${docPath}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor.`,
              );
              continue;
            }

            // Reject injection tokens.
            if (INJECTION_RE.test(anchorCmd)) {
              violations.push(
                `context-factcheck-guard: ${docPath}:${linenum} disallowed token in probe command. Only allowlisted verbs are permitted.`,
              );
              continue;
            }

            // Check each pipe-segment verb.
            const segments = anchorCmd.split("|");
            let verbDenied = false;
            for (const seg of segments) {
              const verb = seg.trimStart().split(/\s+/)[0];
              if (!verb) continue;
              if (!isAllowedVerb(verb)) {
                violations.push(
                  `context-factcheck-guard: ${docPath}:${linenum} disallowed probe verb '${verb}'. Allowed: ${[...ALLOWED_VERBS].join(" ")}.`,
                );
                verbDenied = true;
                break;
              }
            }
            if (verbDenied) continue;

            // Run probe with cwd pinned (fail-open on infra faults).
            let probeOut: string;
            try {
              probeOut = execSync(`cd ${JSON.stringify(cwd)} && ${anchorCmd}`, {
                encoding: "utf8",
                shell: "/bin/bash",
              });
            } catch {
              // Probe exit non-zero → fail-open.
              continue;
            }

            const probeInt = probeOut.trim().replace(/\s/g, "");

            // Non-integer → fail-open.
            if (!/^[0-9]+$/.test(probeInt)) {
              continue;
            }

            // Mismatch → deny.
            if (probeInt !== anchorNnn) {
              violations.push(
                `context-factcheck-guard: ${docPath}:${linenum} claims ${anchorNnn} but the count probe returns ${probeInt}. Update the count or the docs.`,
              );
            }
          } else if (/<!--\s*count:\s*.+-->[^0-9]/.test(line)) {
            // Has count anchor but NNN is non-integer → deny.
            const nnnVal = line
              .replace(/.*-->/, "")
              .replace(/\s/g, "")
              .match(/^[^<]*/)?.[0];
            if (nnnVal && !/^[0-9]+$/.test(nnnVal)) {
              violations.push(
                `context-factcheck-guard: ${docPath}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor.`,
              );
            }
          }
        }
      }

      if (violations.length > 0) {
        return deny(violations.join("\n"));
      }
    } catch {
      // Not in a git repo or infra fault — pass through (fail-open).
    }
  });
}
