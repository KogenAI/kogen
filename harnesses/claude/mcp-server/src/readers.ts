// readers.ts — role-less read-only tools: gate_status (gate-result.json) and
// log_read (cycle log JSONL projections). Neither writes anything.
//
// Log-path resolution mirrors codegen-log's own documented precedence
// (shared/rules/_core/session-log.md § Resolution precedence):
//   CODEGEN_LOG_PATH env var > --slug match > .active sentinel > newest mtime.
// This server never re-implements the writer side of that precedence (only
// codegen-log itself writes), it only needs read-side resolution for the
// gate_status/log_read tools.

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

export interface GateStatus {
  verdict: string;
  exit: number | null;
  diff_files_count: number | null;
  ended: string | null;
  witness: string;
}

export function readGateStatus(cwd: string): GateStatus {
  const path = join(cwd, "codegen", "gate-pending", "gate-result.json");
  if (!existsSync(path)) {
    throw new Error(
      `no gate-result.json at ${path} — no gate has run yet in this cwd`,
    );
  }
  const raw = JSON.parse(readFileSync(path, "utf8"));
  return {
    verdict: raw.verdict ?? "",
    exit: typeof raw.exit === "number" ? raw.exit : null,
    diff_files_count:
      typeof raw.diff_files_count === "number" ? raw.diff_files_count : null,
    ended: raw.ended ?? null,
    witness: raw.witness ?? "",
  };
}

function resolveLogPath(
  cwd: string,
  slug?: string,
  envLogPath?: string,
): string {
  const loggingDir = join(cwd, "codegen", "logging");

  const envPath = envLogPath;
  if (envPath && existsSync(envPath)) return envPath;

  if (slug) {
    if (!existsSync(loggingDir)) {
      throw new Error(
        `no cycle log matches slug "${slug}" — ${loggingDir} does not exist`,
      );
    }
    const matches = readdirSync(loggingDir).filter((f) =>
      f.endsWith(`_${slug}_cycle.jsonl`),
    );
    if (matches.length === 0) {
      throw new Error(`no cycle log matches slug "${slug}"`);
    }
    // Newest by stamp (lexicographic stamp prefix sorts chronologically).
    matches.sort();
    return join(loggingDir, matches[matches.length - 1]);
  }

  const activeSentinel = join(loggingDir, ".active");
  if (existsSync(activeSentinel)) {
    const pointed = readFileSync(activeSentinel, "utf8").trim();
    if (pointed && existsSync(pointed)) return pointed;
  }

  if (existsSync(loggingDir)) {
    const candidates = readdirSync(loggingDir)
      .filter((f) => f.endsWith("_cycle.jsonl"))
      .map((f) => join(loggingDir, f));
    if (candidates.length > 0) {
      candidates.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
      return candidates[0];
    }
  }

  throw new Error(
    "no cycle log found (no CODEGEN_LOG_PATH, no slug match, no .active, no logs on disk)",
  );
}

interface LogEvent {
  ev: string;
  role?: string;
  [key: string]: unknown;
}

function readEvents(logPath: string): LogEvent[] {
  const raw = readFileSync(logPath, "utf8");
  return raw
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line) as LogEvent);
}

export type LogView = "manifest" | "retro" | "full";

export interface LogReadResult {
  logPath: string;
  view: LogView;
  events: LogEvent[];
}

/**
 * Project a cycle log by view:
 *  - manifest: the loop's typed files_to_touch events
 *  - retro:    ev:learned events only (ev:no_learning is deliberately
 *              excluded — session-log.md: "invisible to the context-curator")
 *  - full:     every event, call order
 */
/**
 * Hermetic core: envLogPath is REQUIRED (pass "" to mean "no env override"),
 * never implicitly reads process.env. Fixture-driven tests call this
 * directly so no ambient CODEGEN_LOG_PATH from the calling session can leak
 * into a test's expected event count.
 */
export function readLogWithEnv(
  cwd: string,
  view: LogView,
  slug: string | undefined,
  role: string | undefined,
  envLogPath: string,
): LogReadResult {
  const logPath = resolveLogPath(cwd, slug, envLogPath || undefined);
  let events = readEvents(logPath);

  if (view === "manifest") {
    events = events.filter((e) => e.ev === "files_to_touch");
  } else if (view === "retro") {
    events = events.filter((e) => e.ev === "learned");
  }
  // view === "full": no filter.

  if (role) {
    events = events.filter((e) => e.role === role);
  }

  return { logPath, view, events };
}

/**
 * Real-callsite wrapper: supplies the ambient CODEGEN_LOG_PATH env var as
 * the override, matching codegen-log's own documented resolution precedence
 * for a live MCP tool call inside a real build session.
 */
export function readLog(
  cwd: string,
  view: LogView,
  slug?: string,
  role?: string,
): LogReadResult {
  return readLogWithEnv(
    cwd,
    view,
    slug,
    role,
    process.env.CODEGEN_LOG_PATH ?? "",
  );
}
