/**
 * curator-context-size-gate.ts — Pi enforcement: deny ANY role's write/edit
 * to context/<file>.md, PROJECT_CONTEXT.md, or codegen/PROJECT_CONTEXT.md
 * when the projected post-write byte size would exceed the 40,960-byte
 * (40k) cap.
 *
 * Mirrors: harnesses/claude/hooks/curator-context-size-gate.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: write|edit
 *
 * Gates ANY role's write to context/*.md, PROJECT_CONTEXT.md, or
 * codegen/PROJECT_CONTEXT.md — any role may legitimately edit these docs
 * (e.g. developer, when the pitch's scope: field lists one). This is the ONLY
 * size enforcement on these paths — there is no commit-time backstop.
 * Unparseable payloads fail open. MultiEdit sums all edits[] deltas rather
 * than failing open.
 *
 * CLAUDE.md/AGENTS.md are deliberately NOT gated here: in downstream repos
 * those are rendered symlinks whose bytes are decided by a .j2 template at
 * render time, not by the editing agent — a byte cap on a rendered artifact
 * would deny a write the agent cannot repair in-turn.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";
import { execFileSync } from "node:child_process";

export const HANDLER_META = {
  name: "curator-context-size-gate",
  event: "tool_call",
  matcher: "write|edit",
} as const;

const CAP = 40960;

function isGatedDoc(relPath: string): { gated: boolean; isRootDoc: boolean } {
  if (relPath === "PROJECT_CONTEXT.md" || relPath === "codegen/PROJECT_CONTEXT.md") {
    return { gated: true, isRootDoc: true };
  }
  // Only direct-child context/<file>.md (parity with sibling doc gates).
  if (/^context\/[^/]+\.md$/.test(relPath)) {
    return { gated: true, isRootDoc: false };
  }
  return { gated: false, isRootDoc: false };
}

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

    // Resolve a repo-relative path so PROJECT_CONTEXT.md at repo root (and
    // codegen/PROJECT_CONTEXT.md) can be matched, not just context/<file>.md.
    const cwd = process.env["CWD"] ?? process.cwd();

    let repoRoot: string;
    try {
      repoRoot = execFileSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], {
        encoding: "utf8",
      }).trim();
    } catch {
      return; // Not a git repo — fail open.
    }
    if (!repoRoot) return;

    const absPath = path.isAbsolute(filePath) ? filePath : path.join(cwd, filePath);
    let absPathReal = absPath;
    try {
      absPathReal = fs.realpathSync(absPath);
    } catch {
      try {
        const parentReal = fs.realpathSync(path.dirname(absPath));
        absPathReal = path.join(parentReal, path.basename(absPath));
      } catch {
        // Parent doesn't exist either — keep absPath as-is.
      }
    }
    const relPath = path.relative(repoRoot, absPathReal);
    if (relPath.startsWith("..") || path.isAbsolute(relPath)) return;

    const { gated, isRootDoc } = isGatedDoc(relPath);
    if (!gated) return;

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
        if (fs.existsSync(absPath)) {
          onDisk = Buffer.byteLength(fs.readFileSync(absPath, "utf8"), "utf8");
        }
        projected =
          onDisk - Buffer.byteLength(oldBlob, "utf8") + Buffer.byteLength(newBlob, "utf8");
      } else {
        const newString = (input["new_string"] as string | undefined) ?? "";
        const oldString = (input["old_string"] as string | undefined) ?? "";
        if (!newString && !oldString) return;
        let onDisk = 0;
        if (fs.existsSync(absPath)) {
          onDisk = Buffer.byteLength(fs.readFileSync(absPath, "utf8"), "utf8");
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
      const remedy = isRootDoc
        ? `${filePath} is editable this turn — compress a Domain Context Files row's keyword cell or relocate prose into the context/*.md file that row points at.`
        : `context/*.md is editable this turn — compress a stale/redundant bullet, relocate a verbose example to another context file, or split to a new context/*.md (add the matching PROJECT_CONTEXT.md Domain Context Files row).`;
      return deny(
        `curator-context-size-gate: your ${toolLabel} to ${filePath} would make it ${projected} bytes, over the ${CAP}-byte (40k) cap. ${remedy} Get the file under 40960 bytes before finishing this cycle.`,
      );
    }
  });
}
