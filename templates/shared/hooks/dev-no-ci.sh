#!/bin/bash
# dev-no-ci.sh — PreToolUse hook: deny gate commands for developer-* agents.
#
# Blocks: make ci / ci-fast / ci-cover / predeploy / llm / llm-phoenix / llm-all
#         bare `mix test` (no path argument)
#         `mix test` with only flags (no path)
#
# Allows: `mix test test/path/file.exs` (specific test file paths)
#
# The dev-gate.sh SubagentStop hook runs the gate after the dev subagent exits.
# Developers MUST NOT run gate commands themselves — this hook enforces that
# across both platform Elixir invocations and direct shell-wrapper sessions
# because it's configured at ~/.claude/settings.json user-scope.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log dev-no-ci "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only enforce for developer-* subagents.
case "$AGENT_TYPE" in
developer-*) ;;
*) exit 0 ;;
esac

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Deny: make ci / make ci-fast / make ci-cover / make predeploy / make llm / make llm-phoenix / make llm-all
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(ci|ci-fast|ci-cover|predeploy|llm|llm-phoenix|llm-all)([[:space:]]|$)'; then
    deny "Dev MUST NOT run gate commands. The dev-gate.sh SubagentStop hook runs the gate after you exit. Specific test files are OK: \`mix test test/path/file.exs\`."
    exit 0
fi

# Deny: coverage flags / artifacts / mix coveralls (any variant).
# Coverage runs full suite — dev MUST NOT. The dev-gate.sh hook handles coverage.
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]])--cover([[:space:]]|$)|\bcoveralls\.(html|json)\b|\bmix[[:space:]]+coveralls\b'; then
    deny "Dev MUST NOT run coverage (--cover, coveralls.html, coveralls.json, mix coveralls). Coverage runs the full suite — the dev-gate.sh SubagentStop hook handles it after you exit."
    exit 0
fi

# Deny: bare `mix test` (no path argument, no flags)
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*mix[[:space:]]+test[[:space:]]*$'; then
    deny "Bare \`mix test\` runs full suite — dev MUST NOT. Use \`mix test test/path/file.exs\` for specific files."
    exit 0
fi

# Deny: `mix test` with only flags (no path) — e.g. `mix test --trace --max-cases 1`
# A test file path contains "/" or ends with ".exs". If no such token exists, it's a full-suite run.
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*mix[[:space:]]+test[[:space:]]+--'; then
    has_path=$(printf '%s' "$COMMAND" | grep -oE '[^[:space:]]+' | grep -E '(/|\.exs$)' | head -1 || true)
    if [ -z "$has_path" ]; then
        deny "\`mix test\` with only flags (no path) runs full suite — dev MUST NOT. Specify a test file path, e.g. \`mix test test/path/file.exs\`."
        exit 0
    fi
fi

exit 0
