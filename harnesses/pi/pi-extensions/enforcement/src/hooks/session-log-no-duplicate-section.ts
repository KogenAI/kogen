/**
 * session-log-no-duplicate-section.ts — Pi enforcement: deny session-log
 * Edit/Write payloads that would create a duplicate "## <X> Section" header.
 *
 * Mirrors: harnesses/claude/hooks/session-log-no-duplicate-section.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: write|edit
 *
 * Fires for orchestrator and subagents alike. Bypasses debug/shape/ops roles.
 * Fails open when the on-disk log file is unreadable.
 *
 * Pi has no MultiEdit — handles write (dup-in-content) and edit
 * (payload self-dup + on-disk dup).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";

export const HANDLER_META = {
  name: "session-log-no-duplicate-section",
  event: "tool_call",
  matcher: "write|edit",
} as const;

/** Extract all "## <X> Section" header lines from a text blob. */
function sectionHeaders(text: string): string[] {
  return text
    .split("\n")
    .filter((line) => /^## .+ Section$/.test(line));
}

/** Return the first string that appears more than once, or null. */
function firstDuplicate(items: string[]): string | null {
  const seen = new Set<string>();
  for (const item of items) {
    if (seen.has(item)) return item;
    seen.add(item);
  }
  return null;
}

/**
 * Return the first recognized section header whose body has no non-heading
 * content, or null if every recognized section has real body text.
 */
function firstEmptyRecognizedSection(blob: string): string | null {
  const lines = blob.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!/^## .+ Section$/.test(line) && line !== "## Plan") continue;

    let hasBody = false;
    for (let j = i + 1; j < lines.length; j++) {
      const next = lines[j];
      if (next.startsWith("## ")) break;
      if (next.trim() === "") continue;
      if (next.startsWith("#")) continue;
      hasBody = true;
      break;
    }

    if (!hasBody) return line;
  }

  return null;
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
      "session-log-no-duplicate-section",
      `tool=${event.toolName} file=${filePath}`,
    );

    if (event.toolName === "write") {
      const content: string =
        (event.input as { content?: string }).content ?? "";
      const headers = sectionHeaders(content);
      const dup = firstDuplicate(headers);
      if (dup) {
        return deny(
          `BLOCKED by session-log-no-duplicate-section: Write content contains a duplicate header "${dup}". Each \`## <role> Section\` must appear exactly once — remove the extra copy and rewrite.`,
        );
      }

      const emptySection = firstEmptyRecognizedSection(content);
      if (emptySection) {
        return deny(
          `BLOCKED by session-log-no-duplicate-section: section "${emptySection}" has no non-heading body content — fill the section before writing the session log.`,
        );
      }
      return;
    }

    // edit tool
    const newString: string =
      (event.input as { new_string?: string }).new_string ?? "";

    // Self-duplicate within the payload.
    const payloadHeaders = sectionHeaders(newString);
    const selfDup = firstDuplicate(payloadHeaders);
    if (selfDup) {
      return deny(
        `BLOCKED by session-log-no-duplicate-section: this Edit adds the header "${selfDup}" more than once. Insert each \`## <role> Section\` exactly once.`,
      );
    }

    // Result-simulation: apply old→new to disk content, then check for duplicates.
    const oldString: string =
      (event.input as { old_string?: string }).old_string ?? "";

    try {
      if (fs.existsSync(filePath)) {
        const diskContent = fs.readFileSync(filePath, "utf8");
        const simulated = oldString === ""
          ? diskContent + newString
          : diskContent.replace(oldString, newString);
        const dup = firstDuplicate(sectionHeaders(simulated));
        if (dup) {
          return deny(
            `BLOCKED by session-log-no-duplicate-section: "${dup}" already exists in this log — do NOT re-add it; skip the header Edit and proceed to spawn (the presence guard is already satisfied). Switch to \`(pass N)\` if intentional re-spawn.`
          );
        }

        const emptySection = firstEmptyRecognizedSection(simulated);
        if (emptySection) {
          return deny(
            `BLOCKED by session-log-no-duplicate-section: section "${emptySection}" has no non-heading body content — fill the section before editing the session log.`,
          );
        }
      }
      // File absent → fail open (allow).
    } catch {
      // File unreadable → fail open (allow).
    }
  });
}
