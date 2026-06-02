/**
 * hook-helpers.ts — Pi extension equivalents of hooks-lib.sh helpers.
 *
 * Mirrors the shell helpers from templates/shared/hooks/lib/hooks-lib.sh
 * for use in TypeScript Pi extension hook modules.
 */

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
 * Given an absolute or relative path, returns the path relative to the project
 * root (CWD / CLAUDE_PROJECT_DIR / process.cwd()). If the canonicalised path
 * does not start with the cwd prefix it is returned as-is (absolute).
 *
 * Mirrors repo_relative() in hooks-lib.sh — bash↔TS parity is critical.
 */
export function repoRelative(filePath: string): string {
  // Relative paths are already repo-relative — pass through unchanged.
  // Only absolute paths need cwd-prefix stripping (with symlink resolution
  // so /tmp → /private/tmp works on macOS).
  if (!path.isAbsolute(filePath)) {
    return filePath;
  }
  const canonical = resolveRealPath(filePath);
  const rawCwd =
    process.env["CWD"] ?? process.env["CLAUDE_PROJECT_DIR"] ?? process.cwd();
  // Canonicalise cwd too — on macOS /tmp is a symlink to /private/tmp.
  const canonicalCwd = resolveRealPath(rawCwd);
  const cwdWithSlash = canonicalCwd.endsWith("/")
    ? canonicalCwd
    : canonicalCwd + "/";
  if (canonical.startsWith(cwdWithSlash)) {
    return canonical.slice(cwdWithSlash.length);
  }
  return canonical;
}

/** Unused ctx parameter helper — avoids lint warnings in hook modules that don't use ctx. */
export function voidCtx(_ctx: ExtensionContext): void {
  // intentionally unused
}
