/**
 * context-factcheck-edit-gate.ts — Pi enforcement: deny ANY role's
 * write/edit to an orientation doc (CLAUDE.md, AGENTS.md, PROJECT_CONTEXT.md,
 * codegen/PROJECT_CONTEXT.md, context/*.md) when the PROJECTED post-write
 * content contains a factcheck violation (named-path claim, count-anchor
 * mismatch, or `_`->`*` identifier corruption).
 *
 * Mirrors: harnesses/claude/hooks/context-factcheck-edit-gate.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: write|edit
 *
 * Projection mechanic: materializes the projected post-write body for the
 * target doc, mirrors it into a throwaway git-initialized temp directory at
 * the SAME relative path (plus a placeholder PROJECT_CONTEXT.md so the
 * layout-detection in context-factcheck-scan.sh resolves), then shells the
 * UNCHANGED bash scan primitive (lib/context-factcheck-scan.sh) against
 * that mirror — single-sourced with the .sh twin and the in-loop Elixir step.
 *
 * Supersedes the deleted context-factcheck-curator-stop.ts (session_shutdown,
 * observe-only) — this hook can actually BLOCK, in the writer's own turn.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execFileSync } from "node:child_process";

export const HANDLER_META = {
  name: "context-factcheck-edit-gate",
  event: "tool_call",
  matcher: "write|edit",
} as const;

// Resolved relative to this compiled file at runtime:
// harnesses/pi/pi-extensions/enforcement/dist/hooks/ -> ../../../../../claude/hooks/lib
const SCAN_LIB = path.resolve(
  __dirname,
  "../../../../../claude/hooks/lib/context-factcheck-scan.sh",
);

function isOrientationDoc(relPath: string): boolean {
  if (
    relPath === "CLAUDE.md" ||
    relPath === "AGENTS.md" ||
    relPath === "PROJECT_CONTEXT.md" ||
    relPath === "codegen/PROJECT_CONTEXT.md"
  ) {
    return true;
  }
  // Direct-child context/*.md only (subdirs excluded — parity with sibling gates).
  return /^context\/[^/]+\.md$/.test(relPath);
}

function applyFirstMatch(body: string, oldStr: string, newStr: string): string {
  const idx = body.indexOf(oldStr);
  if (idx === -1 || oldStr === "") return body;
  return body.slice(0, idx) + newStr + body.slice(idx + oldStr.length);
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    const toolName = event.toolName;
    if (!(toolName === "write" || toolName === "edit" || toolName === "multiedit")) {
      return;
    }

    const input = event.input as Record<string, unknown>;
    const filePath = (input["file_path"] as string | undefined) ?? "";
    debugLog("context-factcheck-edit-gate", `tool=${toolName} file=${filePath}`);
    if (!filePath) return;

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
    // Canonicalize both sides before the relative computation — repoRoot
    // came back from `git rev-parse --show-toplevel`, which resolves
    // symlinks (e.g. macOS /tmp -> /private/tmp); absPath did not go
    // through the same resolution. Non-existent absPath (a brand-new
    // Write target) has no realpath — resolve only its existing parent
    // directory and rejoin the basename.
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
    if (!isOrientationDoc(relPath)) return;

    let projected = "";
    try {
      if (toolName === "write") {
        projected = (input["content"] as string | undefined) ?? "";
        if (!projected) return;
      } else if (toolName === "multiedit") {
        const edits = input["edits"] as Array<Record<string, unknown>> | undefined;
        if (!edits || edits.length === 0) return;
        projected = fs.existsSync(absPath) ? fs.readFileSync(absPath, "utf8") : "";
        for (const e of edits) {
          const oldStr = (e["old_string"] as string | undefined) ?? "";
          const newStr = (e["new_string"] as string | undefined) ?? "";
          if (oldStr) projected = applyFirstMatch(projected, oldStr, newStr);
        }
      } else {
        const oldStr = (input["old_string"] as string | undefined) ?? "";
        const newStr = (input["new_string"] as string | undefined) ?? "";
        if (!oldStr && !newStr) return;
        const onDisk = fs.existsSync(absPath) ? fs.readFileSync(absPath, "utf8") : "";
        projected = applyFirstMatch(onDisk, oldStr, newStr);
      }
    } catch {
      return; // Unparseable payload — fail open.
    }

    if (!projected) return;

    let tmpRoot = "";
    try {
      tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "factcheck-edit-gate-"));
      const destPath = path.join(tmpRoot, relPath);
      fs.mkdirSync(path.dirname(destPath), { recursive: true });
      fs.writeFileSync(destPath, projected, "utf8");
      if (relPath !== "PROJECT_CONTEXT.md") {
        fs.writeFileSync(path.join(tmpRoot, "PROJECT_CONTEXT.md"), "", "utf8");
      }
      execFileSync("git", ["init", "-q"], { cwd: tmpRoot });

      let scanOut = "";
      let scanRc = 0;
      try {
        scanOut = execFileSync("bash", [SCAN_LIB, tmpRoot, relPath], {
          encoding: "utf8",
        });
      } catch (err) {
        const e = err as { status?: number; stdout?: string };
        scanRc = e.status ?? 1;
        scanOut = e.stdout ?? "";
      }

      if (scanRc === 1 && scanOut) {
        return deny(
          `${scanOut}\ncontext/*.md is editable this turn — fix before finishing this cycle.`,
        );
      }
    } catch {
      return; // Infra fault materializing the projection — fail open.
    } finally {
      if (tmpRoot) {
        try {
          fs.rmSync(tmpRoot, { recursive: true, force: true });
        } catch {
          // best-effort cleanup
        }
      }
    }
  });
}
