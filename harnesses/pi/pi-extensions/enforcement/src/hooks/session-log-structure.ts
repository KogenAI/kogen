/**
 * session-log-structure.ts — Pi enforcement: deny session-log Edit/Write
 * payloads that violate canonical section order or clobber existing headers.
 *
 * Mirrors: harnesses/claude/hooks/session-log-structure.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: write|edit
 *
 * Enforces two invariants on codegen/logging/*.md files:
 *   1. ORDER — recognized ## headers must appear in non-decreasing phase rank.
 *   2. NO-CLOBBER — an Edit/Write must not remove any existing `## ` header.
 *
 * Bypasses debug/shape/ops roles. Fails open when disk file is unreadable.
 * Pi has no MultiEdit — handles write and edit only.
 *
 * LIMITATION: mid-insert order under-detection — when an Edit inserts a new
 * header in the middle of existing content, the check merges disk+new_string
 * and may miss subtle mid-sequence insertion violations.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";

export const HANDLER_META = {
  name: "session-log-structure",
  event: "tool_call",
  matcher: "write|edit",
} as const;

/**
 * Canonical phase ranks for recognized ## header patterns.
 * NOTE: H1 single-hash lines are NOT ranked — they would false-positive on
 * code-block comment lines starting with "# ". Order enforcement is H2-only.
 */
function rankOf(line: string): number | null {
  if (line === "## Version Stamp") return 1;
  if (/^## Rules Loaded/.test(line)) return 2;
  if (/^## Plan/.test(line)) return 3;
  if (/^## Slices/.test(line)) return 3;
  if (/^## Delegation Timeline/.test(line)) return 4;
  if (/^## Files Modified/.test(line)) return 5;
  if (/^## developer-.+ Section/.test(line)) return 6;
  if (/^## reviewer-.+ Section/.test(line)) return 8;
  if (/^## context-curator Section/.test(line)) return 9;
  if (/^## committer Section/.test(line)) return 10;
  return null;
}

/**
 * checkOrder — scan blob lines; return the first out-of-order header, or null.
 * Ignores unrecognized headers (null rank).
 */
function checkOrder(blob: string): string | null {
  let prevRank = 0;
  for (const line of blob.split("\n")) {
    // Only check H2 (## ) header lines; skip H1 and deeper to avoid
    // false-positives from code-block comment lines starting with "# ".
    if (!line.startsWith("## ")) continue;
    const rank = rankOf(line);
    if (rank === null) continue;
    if (rank < prevRank) return line;
    prevRank = rank;
  }
  return null;
}

/** Extract all lines starting with `## ` from a text blob. */
function h2Headers(text: string): string[] {
  return text.split("\n").filter((l) => l.startsWith("## "));
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "write" && event.toolName !== "edit") return;

    // Investigative-mode bypass (sibling-guard convention).
    const role =
      process.env["CLAUDE_ROLE"] || process.env["PI_ROLE"] || "";
    if (role === "debug" || role === "shape" || role === "ops") return;

    const filePath: string =
      (event.input as { path?: string; file_path?: string }).path ??
      (event.input as { path?: string; file_path?: string }).file_path ??
      "";

    if (!filePath) return;

    // Only gate session log files.
    if (!filePath.includes("codegen/logging/") || !filePath.endsWith(".md"))
      return;

    debugLog(
      "session-log-structure",
      `tool=${event.toolName} file=${filePath}`,
    );

    if (event.toolName === "write") {
      const content: string =
        (event.input as { content?: string }).content ?? "";

      // No-clobber: if file already exists, every disk ## header must appear in content.
      try {
        if (fs.existsSync(filePath)) {
          const diskContent = fs.readFileSync(filePath, "utf8");
          for (const hdr of h2Headers(diskContent)) {
            if (!content.split("\n").includes(hdr)) {
              return deny(
                `BLOCKED by session-log-structure: Write would remove existing header "${hdr}" — use Edit to update sections, never full-file Write on an existing log.`,
              );
            }
          }
        }
      } catch {
        // Unreadable disk file → fail open.
        return;
      }

      // Order check on full content.
      const offender = checkOrder(content);
      if (offender) {
        return deny(
          `BLOCKED by session-log-structure: header "${offender}" appears out of canonical phase order — see session-log.md § Canonical Section Order.`,
        );
      }
      return;
    }

    // edit tool
    const oldString: string =
      (event.input as { old_string?: string }).old_string ?? "";
    const newString: string =
      (event.input as { new_string?: string }).new_string ?? "";

    // No-clobber: any ## header in old_string must also appear in new_string.
    const newLines = new Set(newString.split("\n"));
    for (const hdr of h2Headers(oldString)) {
      if (!newLines.has(hdr)) {
        return deny(
          `BLOCKED by session-log-structure: Edit removes header "${hdr}" from old_string without preserving it in new_string — session log headers must not be deleted.`,
        );
      }
    }

    // Order check: simulate the post-edit file and verify order.
    try {
      if (fs.existsSync(filePath)) {
        const diskContent = fs.readFileSync(filePath, "utf8");
        const simulated = oldString === ""
          ? diskContent + newString
          : diskContent.replace(oldString, newString);
        const offender = checkOrder(simulated);
        if (offender) {
          return deny(
            `BLOCKED by session-log-structure: header "${offender}" appears out of canonical phase order — see session-log.md § Canonical Section Order.`,
          );
        }
      }
      // File absent → fail open (allow).
    } catch {
      // Unreadable disk file → fail open.
    }
  });
}
