/**
 * context-factcheck-curator-stop.ts — Pi enforcement: warn when the
 * context-curator's working-tree orientation docs contain named-path claims
 * that don't resolve or <!-- count: CMD -->NNN anchors whose live probe
 * mismatches NNN.
 *
 * Mirrors: harnesses/claude/hooks/context-factcheck-curator-stop.sh
 * Event: session_shutdown (SubagentStop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * Scans the WORKING TREE (disk), not the staged blob — reads context/*.md,
 * CLAUDE.md, AGENTS.md, PROJECT_CONTEXT.md, codegen/PROJECT_CONTEXT.md as
 * they exist on disk at curator-stop time. On the claude harness the sibling
 * .sh twin BLOCKS the curator so it fixes before yielding to the committer
 * (which cannot Read/Edit context/*.md). Pi's session_shutdown cannot block,
 * so this twin is a diagnostic warning only; pi's commit-time
 * context-factcheck-guard.ts remains the pi backstop for this class of bug.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog, parseAgentType } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";
import { execSync } from "node:child_process";

export const HANDLER_META = {
  name: "context-factcheck-curator-stop",
  event: "session_shutdown",
  matcher: "context-curator",
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

// Elixir source-root fallback: `widgetapp/billing.ex` (module convention)
// commonly resolves at lib/widgetapp/billing.ex or
// test/widgetapp/billing_test.ex. Only tried on literal-miss, only for
// .ex/.exs — can never mask a real bare-root miss.
function resolvesUnderSourceRoot(cwd: string, claimPath: string): boolean {
  if (!/\.exs?$/.test(claimPath)) return false;
  return (
    fs.existsSync(path.join(cwd, "lib", claimPath)) ||
    fs.existsSync(path.join(cwd, "test", claimPath))
  );
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
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    if (agentType !== "context-curator") return;

    const cwd = process.env["CWD"] ?? process.cwd();
    debugLog("context-factcheck-curator-stop", `cwd=${cwd}`);

    try {
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

      // Build the list of working-tree orientation docs to scan.
      const docs: string[] = [];
      for (const fixedDoc of [
        "CLAUDE.md",
        "AGENTS.md",
        "PROJECT_CONTEXT.md",
        "codegen/PROJECT_CONTEXT.md",
      ]) {
        if (fs.existsSync(path.join(cwd, fixedDoc))) {
          docs.push(fixedDoc);
        }
      }
      const contextDir = path.join(cwd, "context");
      if (fs.existsSync(contextDir) && fs.statSync(contextDir).isDirectory()) {
        const ctxFiles = fs
          .readdirSync(contextDir)
          .filter((f) => f.endsWith(".md"))
          .sort();
        for (const f of ctxFiles) {
          docs.push(`context/${f}`);
        }
      }

      if (docs.length === 0) return;

      const violations: string[] = [];

      for (const docPath of docs) {
        let blob: string;
        try {
          blob = fs.readFileSync(path.join(cwd, docPath), "utf8");
        } catch {
          continue;
        }
        if (!blob) continue;

        const lines = blob.split("\n");
        for (let i = 0; i < lines.length; i++) {
          const line = lines[i];
          const linenum = i + 1;

          // ── Claim class 1: named-path probes ──────────────────────────────
          const namedPaths = extractNamedPaths(line);
          for (const claimPath of namedPaths) {
            if (
              !fs.existsSync(path.join(cwd, claimPath)) &&
              !resolvesUnderSourceRoot(cwd, claimPath)
            ) {
              violations.push(
                `context-factcheck-curator-stop: ${docPath}:${linenum} references \`${claimPath}\` which does not exist. Fix the path or remove the claim.`,
              );
            }
          }

          // ── Claim class 2: count-anchor probes ────────────────────────────
          if (/<!--\s*count:\s*.+-->[0-9]+/.test(line)) {
            const cmdMatch = line.match(/<!--\s*count:\s*(.*?)-->[0-9]/);
            const anchorCmd = cmdMatch ? cmdMatch[1].trimEnd() : "";

            const nnnMatch = line.match(/-->([0-9]+)/);
            const anchorNnn = nnnMatch ? nnnMatch[1] : "";

            if (!anchorNnn || !/^[0-9]+$/.test(anchorNnn)) {
              violations.push(
                `context-factcheck-curator-stop: ${docPath}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor.`,
              );
              continue;
            }

            if (INJECTION_RE.test(anchorCmd)) {
              violations.push(
                `context-factcheck-curator-stop: ${docPath}:${linenum} disallowed token in probe command. Only allowlisted verbs are permitted.`,
              );
              continue;
            }

            const segments = anchorCmd.split("|");
            let verbDenied = false;
            for (const seg of segments) {
              const verb = seg.trimStart().split(/\s+/)[0];
              if (!verb) continue;
              if (!isAllowedVerb(verb)) {
                violations.push(
                  `context-factcheck-curator-stop: ${docPath}:${linenum} disallowed probe verb '${verb}'. Allowed: ${[...ALLOWED_VERBS].join(" ")}.`,
                );
                verbDenied = true;
                break;
              }
            }
            if (verbDenied) continue;

            let probeOut: string;
            try {
              probeOut = execSync(`cd ${JSON.stringify(cwd)} && ${anchorCmd}`, {
                encoding: "utf8",
                shell: "/bin/bash",
              });
            } catch {
              continue;
            }

            const probeInt = probeOut.trim().replace(/\s/g, "");

            if (!/^[0-9]+$/.test(probeInt)) {
              continue;
            }

            if (probeInt !== anchorNnn) {
              violations.push(
                `context-factcheck-curator-stop: ${docPath}:${linenum} claims ${anchorNnn} but the count probe returns ${probeInt}. Update the count or the docs.`,
              );
            }
          } else if (/<!--\s*count:\s*.+-->[^0-9]/.test(line)) {
            const nnnVal = line
              .replace(/.*-->/, "")
              .replace(/\s/g, "")
              .match(/^[^<]*/)?.[0];
            if (nnnVal && !/^[0-9]+$/.test(nnnVal)) {
              violations.push(
                `context-factcheck-curator-stop: ${docPath}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor.`,
              );
            }
          }
        }
      }

      if (violations.length > 0) {
        process.stderr.write(
          `[pi-enforcement:context-factcheck-curator-stop] WARNING: ${violations.join(" | ")}\n`,
        );
      }
    } catch {
      // Not in a git repo or infra fault — pass through (fail-open).
    }
  });
}
