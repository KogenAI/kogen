/**
 * _role.ts — shared Pi enforcement helper: resolve active role + build-mode gate.
 *
 * Mirrors harnesses/claude/hooks/_role.sh (resolve_role + is_build_mode).
 * NOT a hook — exports NO HANDLER_META, so emit-handlers.js skips it.
 * Precedence preserves the Pi convention: PI_ROLE > CLAUDE_ROLE.
 */

const INVESTIGATIVE = new Set(["shape", "debug", "ops", "experiment", "refactor"]);

/** Resolve the active Pi role (PI_ROLE primary). Empty = build/unknown. */
export function resolveRole(): string {
  return process.env["PI_ROLE"] ?? process.env["CLAUDE_ROLE"] ?? "";
}

/**
 * Build-cycle gate. True for build, empty, and any unknown role (fail-safe);
 * false only for named investigative modes.
 */
export function isBuildMode(): boolean {
  return !INVESTIGATIVE.has(resolveRole());
}
