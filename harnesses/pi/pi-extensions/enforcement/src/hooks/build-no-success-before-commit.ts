/**
 * build-no-success-before-commit.ts — Pi enforcement: block BUILD_RESULT: before
 * a commit has been made.
 *
 * Mirrors: templates/shared/hooks/build-no-success-before-commit.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "build-no-success-before-commit",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string = (event.input as { command?: string }).command ?? "";

    if (!command.includes("BUILD_RESULT:")) return;

    const buildStartTs = process.env["CODEGEN_BUILD_START_TS"];
    if (!buildStartTs) {
      debugLog(
        "build-no-success-before-commit",
        "allow: CODEGEN_BUILD_START_TS unset",
      );
      return;
    }

    const startTs = parseInt(buildStartTs, 10);
    debugLog("build-no-success-before-commit", `build_start_ts=${startTs}`);

    let commitFound = false;
    try {
      const lastCommitTs = execSync("git log -1 --format=%ct", {
        encoding: "utf8",
      }).trim();

      if (lastCommitTs && parseInt(lastCommitTs, 10) > startTs) {
        commitFound = true;
      }
    } catch {
      // No commits or not in a git repo
    }

    if (!commitFound) {
      return deny(
        "BLOCKED by build-no-success-before-commit: cannot signal BUILD_RESULT: before a commit has been made. Commit your changes first.",
      );
    }

    // Require structured gate-result.json with verdict=clear (parity with .sh backstop).
    let gateVerdict = "";
    try {
      const raw = fs.readFileSync(
        path.join(process.cwd(), "codegen/gate-pending/gate-result.json"),
        "utf8",
      );
      gateVerdict = (JSON.parse(raw).verdict as string) ?? "";
    } catch {
      // No gate-result.json — treat as absent (non-clear)
    }
    if (gateVerdict !== "clear") {
      return deny(
        `BLOCKED by build-no-success-before-commit: gate-result.json does not show verdict=clear (current verdict: '${gateVerdict || "absent"}'). A gate must run and produce a clear verdict before signaling SHIPPED.`,
      );
    }

    // Require a clean working tree — no uncommitted or untracked files.
    // Repo presence was already proven above (commit-timestamp check succeeded),
    // so a throw here is an unexpected git failure, not repo-absence — deny.
    try {
      const porcelain = execSync("git status --porcelain", {
        encoding: "utf8",
      }).trim();

      if (porcelain) {
        const lines = porcelain.split("\n").filter(Boolean);
        const count = lines.length;
        const fileList = lines.map((l) => l.replace(/^\S+\s+/, "")).join(", ");
        return deny(
          `BLOCKED by build-no-success-before-commit: working tree not clean — ${count} file(s) uncommitted: ${fileList}. Commit all cycle output in one commit before signaling SHIPPED.`,
        );
      }
    } catch (e) {
      return deny(
        `BLOCKED by build-no-success-before-commit: 'git status --porcelain' failed unexpectedly (${(e as Error).message}). Cannot verify clean working tree — resolve the git error before signaling SHIPPED.`,
      );
    }

    // OCG-repo check
    const rulesLink = path.join(process.cwd(), "codegen/rules");
    try {
      const stat = fs.lstatSync(rulesLink);
      if (stat.isSymbolicLink()) {
        const rulesTarget = fs.realpathSync(rulesLink);
        const ocgRoot = execSync("git rev-parse --show-toplevel", { cwd: rulesTarget, encoding: "utf8" }).trim();
        const projectRoot = execSync("git rev-parse --show-toplevel", { cwd: process.cwd(), encoding: "utf8" }).trim();
        if (ocgRoot && ocgRoot !== projectRoot) {
          const ocgDirty = execSync("git status --porcelain", { cwd: ocgRoot, encoding: "utf8" }).trim();
          if (ocgDirty) {
            return deny(`BUILD_RESULT: success blocked — OCG repo has uncommitted changes.\nOCG root: ${ocgRoot}\nDirty files:\n${ocgDirty}\n\nCommit the OCG repo first (per orchestrator §Curator & Dual-Repo Commit case 3), then re-emit BUILD_RESULT.`);
          }
        }
      }
    } catch {
      // fail-open: symlink unresolvable or not a git repo
    }

    return;
  });
}
