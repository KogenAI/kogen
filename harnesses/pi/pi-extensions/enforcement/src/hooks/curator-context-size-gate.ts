/**
 * curator-context-size-gate.ts — Pi enforcement: deny a context-curator
 * write/edit to context/<file>.md when the projected post-write byte size
 * would exceed the 40,960-byte (40k) cap.
 *
 * Mirrors: harnesses/claude/hooks/curator-context-size-gate.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: write|edit
 *
 * Gates ANY role's write to context/*.md — any role may legitimately edit
 * context files (e.g. developer, when planner marks one (EDIT)/(NEW)).
 * Unparseable payloads fail open (backstop context-file-size-gate.ts catches
 * at commit). MultiEdit sums all edits[] deltas rather than failing open.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";

export const HANDLER_META = {
  name: "curator-context-size-gate",
  event: "tool_call",
  matcher: "write|edit",
} as const;

const CAP = 40960;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    const toolName = event.toolName;
    if (!(toolName === "write" || toolName === "edit" || toolName === "multiedit")) {
      return;
    }

    const input = event.input as Record<string, unknown>;
    const filePath = (input["file_path"] as string | undefined) ?? "";
    debugLog("curator-context-size-gate", `tool=${toolName} file=${filePath}`);

    if (!filePath) return;

    // Only direct-child context/<file>.md (parity with commit-time gate).
    if (!/(^|\/)context\/[^/]+\.md$/.test(filePath)) return;

    let projected = 0;
    try {
      if (toolName === "write") {
        const content = input["content"] as string | undefined;
        // empty/missing content = unparseable/absent → fail open
        if (!content) return;
        projected = Buffer.byteLength(content, "utf8");
      } else if (toolName === "multiedit") {
        const edits = input["edits"] as Array<Record<string, unknown>> | undefined;
        if (!edits || edits.length === 0) return;
        const oldBlob = edits.map((e) => (e["old_string"] as string | undefined) ?? "").join("");
        const newBlob = edits.map((e) => (e["new_string"] as string | undefined) ?? "").join("");
        let onDisk = 0;
        if (fs.existsSync(filePath)) {
          onDisk = Buffer.byteLength(fs.readFileSync(filePath, "utf8"), "utf8");
        }
        projected =
          onDisk - Buffer.byteLength(oldBlob, "utf8") + Buffer.byteLength(newBlob, "utf8");
      } else {
        const newString = (input["new_string"] as string | undefined) ?? "";
        const oldString = (input["old_string"] as string | undefined) ?? "";
        if (!newString && !oldString) return;
        let onDisk = 0;
        if (fs.existsSync(filePath)) {
          onDisk = Buffer.byteLength(fs.readFileSync(filePath, "utf8"), "utf8");
        }
        projected =
          onDisk -
          Buffer.byteLength(oldString, "utf8") +
          Buffer.byteLength(newString, "utf8");
      }
    } catch {
      return; // I/O or parse error — fail open.
    }

    if (projected > CAP) {
      const toolLabel = toolName === "multiedit" ? "MultiEdit" : "write";
      return deny(
        `curator-context-size-gate: your ${toolLabel} to ${filePath} would make it ${projected} bytes, over the ${CAP}-byte (40k) cap. context/*.md is editable this turn — compress a stale/redundant bullet, relocate a verbose example to another context file, or split to a new context/*.md (add the matching PROJECT_CONTEXT.md Domain Context Files row). Get the file under 40960 bytes before finishing this cycle.`,
      );
    }
  });
}
