/**
 * context-index-parity.ts — Pi enforcement: block git commits that add/remove
 * context/*.md without updating PROJECT_CONTEXT.md.
 *
 * Mirrors: templates/shared/hooks/context-index-parity.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "context-index-parity",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string = (event.input as { command?: string }).command ?? "";

    if (!/\bgit\s+commit\b/.test(command)) return;
    debugLog("context-index-parity", `cmd=${command}`);

    try {
      const statusLines = execSync("git diff --cached --name-status", {
        encoding: "utf8",
      })
        .split("\n")
        .filter(Boolean);

      // Find context/*.md files that were Added or Deleted (not Modified)
      const contextChanges = statusLines.filter((l) =>
        /^[AD]\s+context\/[^/]+\.md$/.test(l),
      );

      if (contextChanges.length === 0) return;

      // Detect index file
      const cwd = process.cwd();
      let indexFile: string | null = null;
      if (fs.existsSync(path.join(cwd, "PROJECT_CONTEXT.md"))) {
        indexFile = "PROJECT_CONTEXT.md";
      } else if (
        fs.existsSync(path.join(cwd, "codegen", "PROJECT_CONTEXT.md"))
      ) {
        indexFile = "codegen/PROJECT_CONTEXT.md";
      }

      if (!indexFile) return;

      const stagedFiles = execSync("git diff --cached --name-only", {
        encoding: "utf8",
      })
        .split("\n")
        .filter(Boolean);

      if (!stagedFiles.includes(indexFile)) {
        return deny(
          `BLOCKED by context-index-parity: context/*.md added/deleted but ${indexFile} is not staged. Update the index file.`,
        );
      }

      // Existence pass: when PROJECT_CONTEXT.md is staged, check all
      // context/<name>.md tokens in its staged body against disk.
      if (stagedFiles.includes(indexFile)) {
        let stagedBody = "";
        try {
          stagedBody = execSync(`git show :${indexFile}`, {
            encoding: "utf8",
          });
        } catch {
          // Cannot read staged blob — skip existence check
        }

        if (stagedBody) {
          const repoRoot = execSync("git rev-parse --show-toplevel", {
            encoding: "utf8",
          }).trim();

          const refs = [
            ...new Set(
              [...stagedBody.matchAll(/context\/[a-z0-9_-]+\.md/g)].map(
                (m) => m[0],
              ),
            ),
          ];

          const phantoms: string[] = [];
          for (const ref of refs) {
            if (!fs.existsSync(path.join(repoRoot, ref))) {
              phantoms.push(
                `context-index-parity: ${indexFile} row references ${ref} which does not exist. Add the file or remove the row.`,
              );
            }
          }

          if (phantoms.length > 0) {
            return deny(phantoms.join("\n"));
          }
        }
      }
    } catch {
      // Not in a git repo — pass through
    }
  });
}
