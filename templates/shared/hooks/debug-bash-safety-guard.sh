#!/bin/bash
# debug-bash-safety-guard.sh — PreToolUse hook: block destructive Bash in debug sessions.
#
# Active only when CLAUDE_ROLE=debug (set by claude-debug.sh launcher).
# Blocks commands that mutate state: file deletion, DB migrations, git writes,
# package installs that overwrite lockfiles, and server restarts.
#
# Allows: read-only commands (ls, grep, find, git log/diff/status/show,
#         curl for inspection, psql SELECT queries, mix deps.get dry-run, etc.)
#
# Rationale: debug sessions are investigation-only. Destructive commands in a
# debug context are almost always accidents — guard prevents unintended state
# mutation in production-adjacent environments.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log debug-bash-safety-guard "tool=$TOOL_NAME agent=$AGENT_TYPE role=${CLAUDE_ROLE:-} cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only active in debug sessions.
if [ "${CLAUDE_ROLE:-}" != "debug" ]; then
    exit 0
fi

# rm -rf / rm -r (recursive deletion)
if printf '%s' "$COMMAND" | grep -qE '\brm[[:space:]].*-[a-zA-Z]*r[a-zA-Z]*[[:space:]]|\brm[[:space:]].*--recursive\b'; then
    deny "BLOCKED by debug-bash-safety-guard: recursive rm forbidden in debug sessions (read-only investigation)"
    exit 0
fi

# mix ecto.migrate / ecto.rollback / ecto.drop / ecto.reset / ecto.create
if printf '%s' "$COMMAND" | grep -qE '\bmix[[:space:]]+(ecto\.(migrate|rollback|drop|reset|create)|ecto\.setup)\b'; then
    deny "BLOCKED by debug-bash-safety-guard: DB migration/drop commands forbidden in debug sessions"
    exit 0
fi

# git commit / push / reset --hard / rebase / cherry-pick / revert / merge
# (belt-and-suspenders on top of pre-commit-guard which also catches these)
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+(commit|push)\b'; then
    deny "BLOCKED by debug-bash-safety-guard: git write operations forbidden in debug sessions"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+reset\b.*--hard\b'; then
    deny "BLOCKED by debug-bash-safety-guard: git reset --hard forbidden in debug sessions"
    exit 0
fi

# mix deps.get (modifies mix.lock) — allow inspection via mix deps.tree/mix deps
if printf '%s' "$COMMAND" | grep -qE '\bmix[[:space:]]+deps\.get\b'; then
    deny "BLOCKED by debug-bash-safety-guard: mix deps.get modifies mix.lock — forbidden in debug sessions"
    exit 0
fi

# mix run priv/repo/seeds (mutates DB)
if printf '%s' "$COMMAND" | grep -qE '\bmix[[:space:]]+run\b.*seeds\b'; then
    deny "BLOCKED by debug-bash-safety-guard: running seeds mutates DB — forbidden in debug sessions"
    exit 0
fi

# Truncate / DROP TABLE via psql/ecto (destructive SQL)
if printf '%s' "$COMMAND" | grep -qiE '\b(TRUNCATE|DROP[[:space:]]+TABLE|DELETE[[:space:]]+FROM)\b'; then
    deny "BLOCKED by debug-bash-safety-guard: destructive SQL (TRUNCATE/DROP TABLE/DELETE FROM) forbidden in debug sessions"
    exit 0
fi

# Destructive HTTP (curl -X DELETE, POST, PUT, PATCH)
if printf '%s' "$COMMAND" | grep -qE 'curl[[:space:]].*-X[[:space:]]+(DELETE|POST|PUT|PATCH)'; then
    deny "BLOCKED by debug-bash-safety-guard: destructive HTTP (curl -X DELETE/POST/PUT/PATCH) forbidden in debug — investigation only"
    exit 0
fi

# Docker mutations
if printf '%s' "$COMMAND" | grep -qE '\bdocker[[:space:]]+(run|exec|kill|rm|stop|start)\b'; then
    deny "BLOCKED by debug-bash-safety-guard: docker mutations forbidden in debug — investigation only"
    exit 0
fi

# systemctl/launchctl mutations
if printf '%s' "$COMMAND" | grep -qE '\b(systemctl|launchctl)[[:space:]]+(start|stop|restart|reload|enable|disable)\b'; then
    deny "BLOCKED by debug-bash-safety-guard: service control forbidden in debug — investigation only"
    exit 0
fi

# kill/pkill/killall
if printf '%s' "$COMMAND" | grep -qE '\b(kill|pkill|killall)\b'; then
    deny "BLOCKED by debug-bash-safety-guard: kill forbidden in debug — use journalctl/ps for inspection only"
    exit 0
fi

# Network package managers (npm install, pip install, brew install, gem install, pnpm add, cargo add)
if printf '%s' "$COMMAND" | grep -qE '\b(npm|pip|pip3|brew|gem|pnpm|cargo)[[:space:]]+(install|add|update|upgrade|remove)\b'; then
    deny "BLOCKED by debug-bash-safety-guard: package installation forbidden in debug — investigation only"
    exit 0
fi

exit 0
