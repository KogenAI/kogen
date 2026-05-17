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
# harnesses: claude_code
# rationale: CLAUDE_ROLE_FAMILY-keyed; Pi investigation sessions use load-gate not role flags
#
# Active when the active role (via resolve_role) is `debug`, `shape`, or `refactor`.
# Responds to CLAUDE_ROLE (Claude Code), PI_ROLE (PI harness), and CODEX_ROLE
# (Codex) — precedence: CLAUDE_ROLE > PI_ROLE > CODEX_ROLE.
# debug, shape, and refactor are investigation/shaping sessions —
# their only legitimate write surface is codegen/pitches/ (enforced by
# orchestrator-no-source-edit.sh). Destructive Bash in these contexts is
# almost always accidental — especially via Agent-spawned subagents.
#
# Blocks commands that mutate state: file deletion, DB migrations, git writes,
# package installs that overwrite lockfiles, and server restarts.
#
# Allows: read-only commands (ls, grep, find, git log/diff/status/show,
#         curl for inspection, psql SELECT queries, etc.)

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

# Only active in debug, shape, or refactor sessions.
if [ "${role}" != "debug" ] && [ "${role}" != "shape" ] && [ "${role}" != "refactor" ]; then
    exit 0
fi

# rm -rf / rm -r (recursive deletion)
if printf '%s' "$COMMAND" | grep -qE '\brm[[:space:]].*-[a-zA-Z]*r[a-zA-Z]*[[:space:]]|\brm[[:space:]].*--recursive\b'; then
    deny "BLOCKED by claude-debug-bash-guard: recursive rm forbidden in ${role} sessions (read-only investigation)"
    exit 0
fi

# mix ecto.migrate / ecto.rollback / ecto.drop / ecto.reset / ecto.create
if printf '%s' "$COMMAND" | grep -qE '\bmix[[:space:]]+(ecto\.(migrate|rollback|drop|reset|create)|ecto\.setup)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: DB migration/drop commands forbidden in ${role} sessions"
    exit 0
fi

# git commit / push / reset --hard / rebase / cherry-pick / revert / merge
# (belt-and-suspenders on top of pre-commit-guard which also catches these)
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+(commit|push)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: git write operations forbidden in ${role} sessions"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+reset\b.*--hard\b'; then
    deny "BLOCKED by claude-debug-bash-guard: git reset --hard forbidden in ${role} sessions"
    exit 0
fi

# mix deps.get (modifies mix.lock) — allow inspection via mix deps.tree/mix deps
if printf '%s' "$COMMAND" | grep -qE '\bmix[[:space:]]+deps\.get\b'; then
    deny "BLOCKED by claude-debug-bash-guard: mix deps.get modifies mix.lock — forbidden in ${role} sessions"
    exit 0
fi

# mix run priv/repo/seeds (mutates DB)
if printf '%s' "$COMMAND" | grep -qE '\bmix[[:space:]]+run\b.*seeds\b'; then
    deny "BLOCKED by claude-debug-bash-guard: running seeds mutates DB — forbidden in ${role} sessions"
    exit 0
fi

# Truncate / DROP TABLE via psql/ecto (destructive SQL)
if printf '%s' "$COMMAND" | grep -qiE '\b(TRUNCATE|DROP[[:space:]]+TABLE|DELETE[[:space:]]+FROM)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: destructive SQL (TRUNCATE/DROP TABLE/DELETE FROM) forbidden in ${role} sessions"
    exit 0
fi

# Destructive HTTP (curl -X DELETE, POST, PUT, PATCH)
if printf '%s' "$COMMAND" | grep -qE 'curl[[:space:]].*-X[[:space:]]+(DELETE|POST|PUT|PATCH)'; then
    deny "BLOCKED by claude-debug-bash-guard: destructive HTTP (curl -X DELETE/POST/PUT/PATCH) forbidden in ${role} mode — investigation only"
    exit 0
fi

# Docker mutations
if printf '%s' "$COMMAND" | grep -qE '\bdocker[[:space:]]+(run|exec|kill|rm|stop|start)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: docker mutations forbidden in ${role} mode — investigation only"
    exit 0
fi

# systemctl/launchctl mutations
if printf '%s' "$COMMAND" | grep -qE '\b(systemctl|launchctl)[[:space:]]+(start|stop|restart|reload|enable|disable)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: service control forbidden in ${role} mode — investigation only"
    exit 0
fi

# kill/pkill/killall
if printf '%s' "$COMMAND" | grep -qE '\b(kill|pkill|killall)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: kill forbidden in ${role} mode — use journalctl/ps for inspection only"
    exit 0
fi

# Network package managers (npm install, pip install, brew install, gem install, pnpm add, cargo add)
if printf '%s' "$COMMAND" | grep -qE '\b(npm|pip|pip3|brew|gem|pnpm|cargo)[[:space:]]+(install|add|update|upgrade|remove)\b'; then
    deny "BLOCKED by claude-debug-bash-guard: package installation forbidden in ${role} mode — investigation only"
    exit 0
fi

exit 0
