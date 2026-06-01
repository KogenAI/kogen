#!/bin/bash
# orchestrator-no-ci.sh — PreToolUse hook: deny gate commands for orchestrator.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
#
# Only enforces when AGENT_TYPE is empty AND AGENT_ID is empty (orchestrator level).
# Subagents (any non-empty AGENT_TYPE or AGENT_ID) pass through.
# ops mode (CLAUDE_ROLE=ops / PI_ROLE=ops) bypasses via resolve_role() — ops runs on live boxes
# and needs full gate-command access for inspection.
#
# Blocks:
#   make ci / ci-fast / ci-cover / predeploy
#   make llm / llm-phoenix / llm-all / llm-phoenix-seed / llm-phoenix-validate
#        / llm-retry / llm-summary / llm-kill
#   bare mix test (no path), mix test flags-only, mix test --cover, mix coveralls*
#
# Allows (early-return before block regex):
#   make gate-status / gate-logs / gate-kill
#
# Gate commands run via the SubagentStop hook (phoenix-dev-gate.sh) after
# developer-* completes. Orchestrator MUST NOT run them directly.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log orchestrator-no-ci "tool=$TOOL_NAME agent_type=${AGENT_TYPE:-} agent_id=${AGENT_ID:-} cmd=${COMMAND:-}"

# ops mode bypasses: full gate-command access for inspection on live boxes.
_role=$(resolve_role)
[ "$_role" = "ops" ] && exit 0

# Only enforce for orchestrator level (both AGENT_TYPE and AGENT_ID empty)
if [ -n "${AGENT_TYPE:-}" ] || [ -n "${AGENT_ID:-}" ]; then
    debug_log orchestrator-no-ci "skip: subagent (agent_type=${AGENT_TYPE:-} agent_id=${AGENT_ID:-})"
    exit 0
fi

# Only guard Bash tool
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

_deny_gate() {
    deny "orchestrator-no-ci: orchestrator MUST NOT run gate commands directly. Gate runs via the SubagentStop hook (phoenix-dev-gate.sh) after developer-* completes. To inspect a running gate, use \`make gate-status\`. To trigger a gate, delegate to a developer-* subagent."
    exit 0
}

# Allowlist: gate-status / gate-logs / gate-kill — early return before block
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(gate-status|gate-logs|gate-kill)([[:space:]]|$)'; then
    debug_log orchestrator-no-ci "allow: gate management command"
    exit 0
fi

# Block: make ci / ci-fast / ci-cover / predeploy
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(ci|ci-fast|ci-cover|predeploy)([[:space:]]|$|[[:space:]]*2>&1)'; then
    debug_log orchestrator-no-ci "DENY: make ci/ci-fast/ci-cover/predeploy"
    _deny_gate
fi

# Block: make llm / llm-phoenix / llm-all / llm-phoenix-seed / llm-phoenix-validate
#              / llm-retry / llm-summary / llm-kill
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(llm|llm-phoenix|llm-all|llm-phoenix-seed|llm-phoenix-validate|llm-retry|llm-summary|llm-kill)([[:space:]]|$)'; then
    debug_log orchestrator-no-ci "DENY: make llm*"
    _deny_gate
fi

# Block: coverage flags / mix coveralls (any variant)
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]])--cover([[:space:]]|$)|\bcoveralls\.(html|json)\b|\bmix[[:space:]]+coveralls\b'; then
    debug_log orchestrator-no-ci "DENY: coverage command"
    _deny_gate
fi

# Block: bare mix test (no path)
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*mix[[:space:]]+test[[:space:]]*$'; then
    debug_log orchestrator-no-ci "DENY: bare mix test"
    _deny_gate
fi

# Block: mix test with only flags (no path) — any mix test token is off-limits for orchestrator
# Orchestrator NEVER runs tests, even specific files (per roles/orchestrator.md line 11).
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*mix[[:space:]]+test([[:space:]]|$)'; then
    debug_log orchestrator-no-ci "DENY: mix test (orchestrator must not run tests)"
    _deny_gate
fi

exit 0
