/**
 * _waiver.ts — shared Pi enforcement helper: is a guard waived for THIS invocation?
 *
 * Mirrors harnesses/claude/hooks/_waiver.sh.
 * NOT a hook — exports NO HANDLER_META, so emit-handlers.js skips it.
 *
 * isWaived(hookId) returns true iff BOTH:
 *   1. CODEGEN_WAIVED_GUARDS (loop-injected, developer role only) names the id
 *      — proves the loop granted it, to this role, this spawn.
 *   2. codegen/pitches/building/<slug>.md declares the id in `waives:`
 *      — proves a promoted pitch asked for it.
 * Belt and braces: the env carries role+spawn scope the file cannot; the file
 * carries authorization the env cannot (a var can be stale or inherited).
 *
 * Anything absent, empty, unparseable, or a non-waivable registry entry →
 * false (ENFORCE). Fail-safe, mirroring isBuildMode()'s posture.
 *
 * On a granted waiver, appends ev:waiver to the cycle log via the codegen-log
 * binary. That write is fail-loud-non-blocking: stderr on failure, never
 * changes the verdict.
 */

import { execFileSync } from "node:child_process";
import * as fs from "fs";
import * as path from "path";
import { repoRoot } from "../lib/hook-helpers";
import { resolveRole } from "./_role";

function registryAllows(root: string, hookId: string): boolean {
  const reg = path.join(root, "shared/enforcement/registry.yaml");
  if (!fs.existsSync(reg)) return false;
  let text: string;
  try {
    text = fs.readFileSync(reg, "utf8");
  } catch {
    return false;
  }
  const lines = text.split("\n");
  let inBlock = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (/^id:\s+\S+/.test(trimmed)) {
      const [, id] = trimmed.split(/\s+/, 2);
      inBlock = id === hookId;
      continue;
    }
    if (inBlock && trimmed === "") {
      inBlock = false;
      continue;
    }
    if (inBlock && /^waivable:\s*true\s*$/.test(trimmed)) {
      return true;
    }
  }
  return false;
}

function findBuildingPitch(root: string): string | null {
  const dir = path.join(root, "codegen/pitches/building");
  if (!fs.existsSync(dir)) return null;
  let entries: string[];
  try {
    entries = fs.readdirSync(dir).filter((f) => f.endsWith(".md"));
  } catch {
    return null;
  }
  if (entries.length !== 1) return null;
  return path.join(dir, entries[0] as string);
}

function pitchDeclares(root: string, hookId: string): boolean {
  const pitchPath = findBuildingPitch(root);
  if (!pitchPath) return false;
  let text: string;
  try {
    text = fs.readFileSync(pitchPath, "utf8");
  } catch {
    return false;
  }
  const lines = text.split("\n");
  if (lines[0] !== "---") return false;
  let waivesLine: string | null = null;
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i] as string;
    if (line === "---") break;
    if (line.startsWith("waives:")) {
      waivesLine = line;
      break;
    }
  }
  if (!waivesLine) return false;
  const body = waivesLine
    .replace(/^waives:\s*/, "")
    .replace(/[[\]]/g, "");
  const ids = body
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  return ids.includes(hookId);
}

function recordWaiver(root: string, hookId: string): void {
  const pitchPath = findBuildingPitch(root);
  const slug = pitchPath ? path.basename(pitchPath, ".md") : "";
  const role = resolveRole();
  try {
    execFileSync(
      "codegen-log",
      ["append", role, "--waiver", hookId, "--waiver-slug", slug],
      { stdio: ["ignore", "ignore", "ignore"] },
    );
  } catch {
    process.stderr.write(
      `waiver: failed to record ev:waiver for ${hookId} (proceeding)\n`,
    );
  }
}

/** isWaived(hookId) — true = waived (skip the deny), false = enforce. */
export function isWaived(hookId: string): boolean {
  const waivedGuards = process.env["CODEGEN_WAIVED_GUARDS"] ?? "";
  if (!waivedGuards) return false;
  const names = waivedGuards
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (!names.includes(hookId)) return false;

  const root = repoRoot(process.cwd());
  if (!registryAllows(root, hookId)) return false;
  if (!pitchDeclares(root, hookId)) return false;

  recordWaiver(root, hookId);
  return true;
}
