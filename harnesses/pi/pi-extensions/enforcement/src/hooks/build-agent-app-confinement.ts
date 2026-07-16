/**
 * build-agent-app-confinement.ts — Pi enforcement twin of
 * build-agent-app-confinement.sh.
 *
 * Denies write/edit/multiEdit/notebookEdit, and bash write-vocab
 * invocations (redirects, tee, cp/mv/install/rsync, sed -i/perl -pi, dd
 * of=, truncate, ln -s, git apply/checkout --), when CODEGEN_BUILD_CWD is
 * set and the target resolves outside that dir. Full-fidelity port.
 *
 * Escape test: a token ESCAPES iff its lexical form reads as inside the
 * sandbox but its REAL (symlink-resolved) form reads as outside — only a
 * symlink produces that asymmetry. The /tmp scratch hatch is checked AFTER
 * canonicalization (leg B) so a symlink whose lexical path sits under /tmp
 * but resolves outside the sandbox is still denied.
 *
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: write|edit|multiEdit|notebookEdit|bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  deny,
  debugLog,
  resolveRealPath,
  splitCommandSegments,
  commandWordOfSegment,
  segmentArgvOf,
} from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "build-agent-app-confinement",
  event: "tool_call",
  matcher: "write|edit|multiEdit|notebookEdit|bash",
} as const;

const FILE_TOOLS = new Set(["write", "edit", "multiEdit", "notebookEdit"]);

const WRITE_VERB_RE = /^(tee|cp|mv|install|rsync|sed|perl|dd|truncate|ln)$/;
const INTERPRETER_RE = /^(python3?|perl|node|awk|patch|xargs)$/;

function isScratchReal(canon: string): boolean {
  return (
    canon === "/tmp" ||
    canon === "/private/tmp" ||
    canon.startsWith("/tmp/") ||
    canon.startsWith("/private/tmp/") ||
    canon === "/dev/null" ||
    canon === "/dev/stdout" ||
    canon === "/dev/stderr"
  );
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    const buildCwd = process.env["CODEGEN_BUILD_CWD"] ?? "";
    if (!buildCwd) return; // inert outside a managed build

    const canonCwd = resolveRealPath(buildCwd);
    const cwdPrefix = canonCwd.endsWith("/") ? canonCwd : canonCwd + "/";

    const isInsideSandbox = (canon: string): boolean =>
      canon === canonCwd || canon.startsWith(cwdPrefix);

    // checkTarget — canonicalize raw path via resolveRealPath, which resolves
    // relative paths against process.cwd() (path.resolve fallback) — mirrors
    // hooks_realpath's $PWD-prepend semantics exactly. During a real build,
    // process.cwd() == CODEGEN_BUILD_CWD (dispatch execs with cwd set to the
    // sandbox). Return a deny result on escape, or null when allowed
    // (scratch/inside).
    const checkTarget = (raw: string, what: string) => {
      const canon = resolveRealPath(raw);
      if (isScratchReal(canon)) return null;
      if (isInsideSandbox(canon)) return null;
      return deny(
        `BLOCKED by build-agent-app-confinement: managed build agents may only write inside the app sandbox (${canonCwd}). ${what} resolves to ${canon} (outside CODEGEN_BUILD_CWD). Write to a path under the sandbox, or use /tmp for scratch.`,
      );
    };

    if (FILE_TOOLS.has(event.toolName)) {
      const filePath: string =
        (event.input as { path?: string; file_path?: string }).path ??
        (event.input as { path?: string; file_path?: string }).file_path ??
        "";
      if (!filePath) return;

      debugLog(
        "build-agent-app-confinement",
        `tool=${event.toolName} cwd=${canonCwd} file=${filePath}`,
      );

      return checkTarget(filePath, `${event.toolName} target ${filePath}`) ?? undefined;
    }

    if (event.toolName === "bash") {
      const command: string =
        (event.input as { command?: string }).command ?? "";
      if (!command) return;

      debugLog("build-agent-app-confinement", `tool=bash cmd=${command}`);

      const segments = splitCommandSegments(command);
      if (segments === null) {
        // unbalanced quote — fail OPEN here (this hook only denies on a
        // positively identified escaping target); netted by the whole-tree
        // CI drift guard (leg B).
        return;
      }

      for (const seg of segments) {
        if (!seg.trim()) continue;
        const word = commandWordOfSegment(seg);
        const argv = segmentArgvOf(seg);

        let hasWriteIntent = false;
        if (WRITE_VERB_RE.test(word)) hasWriteIntent = true;
        else if (INTERPRETER_RE.test(word)) hasWriteIntent = true;
        else if (word === "git" && /^(apply|checkout\s+--)/.test(argv))
          hasWriteIntent = true;

        if (hasWriteIntent) {
          if (
            word === "cd" ||
            word === "pushd" ||
            /\.\.\//.test(seg)
          ) {
            return deny(
              `BLOCKED by build-agent-app-confinement: Bash segment combines a write-verb/interpreter with cd/pushd/../ — destination cannot be resolved textually inside a managed build (CODEGEN_BUILD_CWD set); failing closed. Split into a plain absolute-path write.`,
            );
          }
        }

        const argvTokens = argv.split(/\s+/).filter((t) => t.length > 0);

        if (word === "tee") {
          for (const tok of argvTokens) {
            if (tok.startsWith("-")) continue;
            const result = checkTarget(tok, `tee destination ${tok}`);
            if (result) return result;
          }
        } else if (
          word === "cp" ||
          word === "mv" ||
          word === "install" ||
          word === "rsync"
        ) {
          const nonFlag = argvTokens.filter((t) => !t.startsWith("-"));
          const last = nonFlag[nonFlag.length - 1];
          if (last) {
            const result = checkTarget(last, `${word} destination ${last}`);
            if (result) return result;
          }
        } else if (word === "sed" || word === "perl") {
          if (/(^|\s)-[a-zA-Z]*i[a-zA-Z]*(\s|$|=)/.test(argv)) {
            for (const tok of argvTokens) {
              if (tok.startsWith("-")) continue;
              const result = checkTarget(tok, `${word} -i operand ${tok}`);
              if (result) return result;
            }
          }
        } else if (word === "dd") {
          for (const tok of argvTokens) {
            if (tok.startsWith("of=")) {
              const target = tok.slice(3);
              const result = checkTarget(target, `dd of= target ${target}`);
              if (result) return result;
            }
          }
        } else if (word === "truncate") {
          for (const tok of argvTokens) {
            if (tok.startsWith("-")) continue;
            const result = checkTarget(tok, `truncate target ${tok}`);
            if (result) return result;
          }
        } else if (word === "ln") {
          const nonFlag = argvTokens.filter((t) => !t.startsWith("-"));
          const linkName = nonFlag[nonFlag.length - 1];
          if (linkName) {
            const result = checkTarget(linkName, `ln link name ${linkName}`);
            if (result) return result;
          }
        } else if (word === "git") {
          const m = argv.match(/^checkout\s+--\s*(.*)$/);
          if (m && m[1]) {
            const target = m[1].trim();
            if (target) {
              const result = checkTarget(
                target,
                `git checkout -- target ${target}`,
              );
              if (result) return result;
            }
          }
        }

        // Redirect operators (> >> N> &>) anywhere in the segment.
        const redirectMatches = [
          ...seg.matchAll(/(?:^|\s)\d*(>>|>|&>)\s*([^\s;|&]+)/g),
        ];
        if (redirectMatches.length > 0) {
          const lastMatch = redirectMatches[redirectMatches.length - 1];
          const redirectTarget = lastMatch[2];
          if (redirectTarget) {
            const result = checkTarget(
              redirectTarget,
              `redirect target ${redirectTarget}`,
            );
            if (result) return result;
          }
        }
      }
    }
  });
}
