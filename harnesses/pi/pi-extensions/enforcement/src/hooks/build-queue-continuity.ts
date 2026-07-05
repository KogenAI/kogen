/**
 * build-queue-continuity.ts — Pi enforcement: warn when the session shuts down
 * with a multi-pitch build queue still unfinished and the current gate not failed.
 *
 * Mirrors: harnesses/claude/hooks/build-queue-continuity.sh
 * Event: session_shutdown (Stop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog } from "../lib/hook-helpers";
import { isBuildMode } from "./_role";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "build-queue-continuity",
  event: "session_shutdown",
  matcher: "*",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    // Investigative-mode skip: observe-only Stop twin enforces only in build
    // mode. Silent early-return on any investigative role — no warning (mirrors
    // signal: CLAUDE_ROLE_FAMILY; misfire warning in investigative mode is noise).
    if (!isBuildMode()) return;

    const projectDir = process.env["CWD"] ?? process.cwd();
    debugLog("build-queue-continuity", `cwd=${projectDir}`);

    const manifestPath = path.join(
      projectDir,
      "codegen",
      "gate-pending",
      "build-queue.json",
    );
    if (!fs.existsSync(manifestPath)) {
      debugLog("build-queue-continuity", "skip: no queue manifest");
      return;
    }

    let slugs: string[];
    let position: number;
    try {
      const m = JSON.parse(fs.readFileSync(manifestPath, "utf8")) as {
        slugs?: string[];
        position?: number;
      };
      if (!Array.isArray(m.slugs) || typeof m.position !== "number") {
        debugLog("build-queue-continuity", "skip: manifest unparseable");
        return;
      }
      slugs = m.slugs;
      position = m.position;
    } catch {
      debugLog("build-queue-continuity", "skip: manifest read/parse error");
      return;
    }

    if (position >= slugs.length) {
      debugLog(
        "build-queue-continuity",
        `skip: queue exhausted (${position}/${slugs.length})`,
      );
      return;
    }

    const gateResultPath = path.join(
      projectDir,
      "codegen",
      "gate-pending",
      "gate-result.json",
    );
    if (fs.existsSync(gateResultPath)) {
      try {
        const g = JSON.parse(
          fs.readFileSync(gateResultPath, "utf8"),
        ) as { verdict?: string };
        if (g.verdict === "failed" || g.verdict === "inconclusive") {
          debugLog(
            "build-queue-continuity",
            `skip: gate verdict=${g.verdict} — mid-queue halt allowed`,
          );
          return;
        }
      } catch {
        // malformed gate-result.json — fall through to warn (queue still pending)
      }
    }

    let remaining = 0;
    let nextSlug = "";
    for (let i = position; i < slugs.length; i += 1) {
      const slug = slugs[i] ?? "";
      if (!slug) continue;
      const shippedPath = path.join(
        projectDir,
        "codegen",
        "pitches",
        "shipped",
        `${slug}.md`,
      );
      if (fs.existsSync(shippedPath)) {
        debugLog("build-queue-continuity", `skip shipped slug=${slug} at position=${i}`);
        continue;
      }
      if (!nextSlug) nextSlug = slug;
      remaining += 1;
    }

    if (!nextSlug) {
      debugLog("build-queue-continuity", "skip: remaining manifest entries already shipped");
      return;
    }

    process.stderr.write(
      `[pi-enforcement:build-queue-continuity] WARNING: ${remaining} queued pitch(es) remain (next: ${nextSlug}). Build-queue continuity is autonomous — do not stop or ask permission; begin the next pitch's cycle.\n`,
    );
  });
}
