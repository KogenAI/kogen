/**
 * claude-debug-bash-guard.ts — Pi enforcement: block destructive Bash during
 * remote debug investigation.
 *
 * Mirrors: harnesses/claude/hooks/claude-debug-bash-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * ID KEPT for parity (registry.yaml D8) despite cross-harness naming — the
 * ID is the stable identity used by generation/parity tooling.
 *
 * Activation differs deliberately from the Claude twin: Claude gates on
 * CLAUDE_ROLE_FAMILY in {debug, shape}. Pi's local debug/shape sessions
 * already carry NO Bash tool grant at all (manifest.yaml modes.debug.tools
 * has no "bash" entry) — there is nothing to guard locally. This twin is
 * ACTIVE ONLY when PI_DEBUG_REMOTE=1, the flag pi-debug's explicit
 * `--server <target>` branch exports before it grants guarded remote Bash.
 * That is the one place Pi Bash exists in an investigation session, so it
 * is the one place this guard needs to run.
 *
 * Command-POSITION-aware: uses commandInvokes(), which matches a forbidden
 * verb only against a shell-chain segment's resolved COMMAND WORD (and,
 * where given, that segment's argv) — never the raw command line.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, commandInvokes, stripGitGlobalOpts } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "claude-debug-bash-guard",
  event: "tool_call",
  matcher: "bash",
} as const;

function commandOf(input: unknown): string {
  return (input as { command?: string }).command ?? "";
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    // Active only on the explicit remote-debug branch (pi-debug --server).
    if (process.env["PI_DEBUG_REMOTE"] !== "1") return;

    const command = commandOf(event.input);
    debugLog("claude-debug-bash-guard", `cmd=${command}`);

    if (
      commandInvokes(
        command,
        /^rm$/,
        /(^|[\s])-[a-zA-Z]*[rR][a-zA-Z]*([\s]|$)|--recursive\b/,
      )
    ) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: recursive rm forbidden in remote-debug sessions (read-only investigation)",
      );
    }

    if (
      commandInvokes(
        command,
        /^mix$/,
        /^(ecto\.(migrate|rollback|drop|reset|create)|ecto\.setup)\b/,
      )
    ) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: DB migration/drop commands forbidden in remote-debug sessions",
      );
    }

    const gitStripped = stripGitGlobalOpts(command);
    if (commandInvokes(gitStripped, /^git$/, /^push\b/)) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: git push forbidden in remote-debug sessions",
      );
    }
    if (commandInvokes(gitStripped, /^git$/, /^reset\b.*--hard\b/)) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: git reset --hard forbidden in remote-debug sessions",
      );
    }

    if (commandInvokes(command, /^mix$/, /^deps\.get\b/)) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: mix deps.get modifies mix.lock — forbidden in remote-debug sessions",
      );
    }

    if (commandInvokes(command, /^mix$/, /^run\b.*seeds\b/)) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: running seeds mutates DB — forbidden in remote-debug sessions",
      );
    }

    if (
      commandInvokes(
        command,
        /^(psql|mix)$/,
        /\b(TRUNCATE|DROP\s+TABLE|DELETE\s+FROM)\b/i,
      )
    ) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: destructive SQL (TRUNCATE/DROP TABLE/DELETE FROM) forbidden in remote-debug sessions",
      );
    }

    if (
      commandInvokes(command, /^curl$/, /(^|[\s])-X\s+(DELETE|POST|PUT|PATCH)\b/)
    ) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: destructive HTTP (curl -X DELETE/POST/PUT/PATCH) forbidden in remote-debug mode — investigation only",
      );
    }

    if (commandInvokes(command, /^docker$/, /^(run|exec|kill|rm|stop|start)\b/)) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: docker mutations forbidden in remote-debug mode — investigation only",
      );
    }

    if (
      commandInvokes(
        command,
        /^(systemctl|launchctl)$/,
        /^(start|stop|restart|reload|enable|disable)\b/,
      )
    ) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: service control forbidden in remote-debug mode — investigation only",
      );
    }

    if (commandInvokes(command, /^(kill|pkill|killall)$/)) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: kill forbidden in remote-debug mode — use journalctl/ps for inspection only",
      );
    }

    if (
      commandInvokes(
        command,
        /^(npm|pip|pip3|brew|gem|pnpm|cargo)$/,
        /^(install|add|update|upgrade|remove)\b/,
      )
    ) {
      return deny(
        "BLOCKED by claude-debug-bash-guard: package installation forbidden in remote-debug mode — investigation only",
      );
    }
  });
}
