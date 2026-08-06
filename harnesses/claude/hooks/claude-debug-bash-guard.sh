#!/bin/bash
# claude-debug-bash-guard.sh — PreToolUse hook: block destructive Bash in
# debug and design sessions.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: *
# harnesses: all
# rationale: CLAUDE_ROLE_FAMILY-keyed launcher mode guard for the debug/shape families
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Active when the active role (via resolve_role) is `debug` or `shape`.
# Responds to CLAUDE_ROLE (Claude Code).
# debug and shape are investigation/shaping sessions —
# their only legitimate write surface is codegen/pitches/ (enforced by
# orchestrator-no-source-edit.sh). Destructive Bash in these contexts is
# almost always accidental — especially via Agent-spawned subagents.
#
# Blocks commands that mutate state: file deletion, DB migrations, git writes,
# package installs that overwrite lockfiles, and server restarts.
#
# Allows: read-only commands (ls, grep, find, git log/diff/status/show,
#         curl for inspection, psql SELECT queries, etc.)
#
# Command-POSITION-aware: every check below uses command_invokes() (see
# hooks-lib.sh), which matches a forbidden verb only against a shell-chain
# segment's resolved COMMAND WORD (and, where given, that segment's argv) —
# never against the raw command line. A mention of a forbidden token inside
# a grep pattern, an echo string, a filename, or a quoted remote-exec
# payload is not an invocation and is never denied; a real invocation is
# denied even when wrapped (`sudo env FOO=1 rm -rf x`) or nested one level
# inside an inline interpreter payload (`bash -c 'kill 123'`).

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

role=$(resolve_role)
debug_log claude-debug-bash-guard "tool=$TOOL_NAME agent=$AGENT_TYPE role=${role} cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only active in debug or shape sessions.
if [ "${role}" != "debug" ] && [ "${role}" != "shape" ]; then
    exit 0
fi

# Parseability check BEFORE any rule-specific command_invokes() call below.
# Every check in this file stays fail-closed on an unparseable command (a
# real unbalanced quote), but the denial must say so honestly — never
# borrow an unrelated rule's message for a command that rule never actually
# matched (that was the bug: command_invokes() used to return 0 — "match"
# — on a parse failure, so whichever rule happened to run first claimed the
# denial for a command it never checked).
if ! split_command_segments "$COMMAND" >/dev/null; then
    deny "BLOCKED by claude-debug-bash-guard: could not parse this command (unbalanced quote) — rewrite it as a single balanced command"
    exit 0
fi

# rm -rf / rm -r (recursive deletion) — anchor on a short flag cluster
# containing r/R (e.g. -r, -rf, -fr, -rfv) anywhere in argv, or the explicit
# --recursive long flag. Must NOT match long flags like --force/--verbose
# whose letters happen to contain 'r' (e.g. the 2nd dash-char run in
# --force) — the argv regex requires a LEADING '-' immediately before the
# r/R-bearing cluster, so --force never matches.
if command_invokes "$COMMAND" '^rm$' '(^|[[:space:]])-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)|--recursive\b'; then
    deny "BLOCKED by claude-debug-bash-guard: recursive rm forbidden in ${role} sessions (read-only investigation)"
    exit 0
fi

# mix ecto.migrate / ecto.rollback / ecto.drop / ecto.reset / ecto.create
if command_invokes "$COMMAND" '^mix$' '^(ecto\.(migrate|rollback|drop|reset|create)|ecto\.setup)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: DB migration/drop commands forbidden in ${role} sessions"
    exit 0
fi

# git push (belt-and-suspenders — pre-commit-guard only blocks `push --force`,
# so plain `git push` needs coverage here; `git commit` is pre-commit-guard's
# job alone — dropped to avoid a redundant duplicate deny). Segments are
# normalized via strip_git_global_opts first so `git -C /x push` still
# resolves the subcommand to argv position 0.
if command_invokes "$(strip_git_global_opts "$COMMAND")" '^git$' '^push\b'; then
    deny "BLOCKED by claude-debug-bash-guard: git push forbidden in ${role} sessions"
    exit 0
fi

if command_invokes "$(strip_git_global_opts "$COMMAND")" '^git$' '^reset\b.*--hard\b'; then
    deny "BLOCKED by claude-debug-bash-guard: git reset --hard forbidden in ${role} sessions"
    exit 0
fi

# mix deps.get (modifies mix.lock) — allow inspection via mix deps.tree/mix deps
if command_invokes "$COMMAND" '^mix$' '^deps\.get\b'; then
    deny "BLOCKED by claude-debug-bash-guard: mix deps.get modifies mix.lock — forbidden in ${role} sessions"
    exit 0
fi

# mix run priv/repo/seeds (mutates DB)
if command_invokes "$COMMAND" '^mix$' '^run\b.*seeds\b'; then
    deny "BLOCKED by claude-debug-bash-guard: running seeds mutates DB — forbidden in ${role} sessions"
    exit 0
fi

# Truncate / DROP TABLE via psql/ecto (destructive SQL) — the SQL verb is
# the argv of psql/ecto/mix, so this checks the command word (psql or mix)
# together with the SQL keyword anywhere in that segment's argv (the SQL
# text is itself the -c/-e argument, not a separate command word).
# Case-insensitive on the SQL keyword only (`ci` flag) — SQL keywords are
# conventionally uppercase but not required to be.
if command_invokes "$COMMAND" '^(psql|mix)$' '\b(TRUNCATE|DROP[[:space:]]+TABLE|DELETE[[:space:]]+FROM)\b' ci; then
    deny "BLOCKED by claude-debug-bash-guard: destructive SQL (TRUNCATE/DROP TABLE/DELETE FROM) forbidden in ${role} sessions"
    exit 0
fi

# Destructive HTTP (curl -X DELETE, POST, PUT, PATCH)
if command_invokes "$COMMAND" '^curl$' '(^|[[:space:]])-X[[:space:]]+(DELETE|POST|PUT|PATCH)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: destructive HTTP (curl -X DELETE/POST/PUT/PATCH) forbidden in ${role} mode — investigation only"
    exit 0
fi

# Docker mutations
if command_invokes "$COMMAND" '^docker$' '^(run|exec|kill|rm|stop|start)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: docker mutations forbidden in ${role} mode — investigation only"
    exit 0
fi

# systemctl/launchctl mutations
if command_invokes "$COMMAND" '^(systemctl|launchctl)$' '^(start|stop|restart|reload|enable|disable)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: service control forbidden in ${role} mode — investigation only"
    exit 0
fi

# kill/pkill/killall
if command_invokes "$COMMAND" '^(kill|pkill|killall)$'; then
    deny "BLOCKED by claude-debug-bash-guard: kill forbidden in ${role} mode — use journalctl/ps for inspection only"
    exit 0
fi

# Network package managers (npm install, pip install, brew install, gem install, pnpm add, cargo add)
if command_invokes "$COMMAND" '^(npm|pip|pip3|brew|gem|pnpm|cargo)$' '^(install|add|update|upgrade|remove)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: package installation forbidden in ${role} mode — investigation only"
    exit 0
fi

exit 0
