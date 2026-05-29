#!/bin/bash
# _role.sh — shared helper: resolve the active role across harnesses.
#
# NOT a registered hook — this is a library helper sourced by hook scripts.
# Prefix "_" prevents hook_registrations.py from registering it.
# Canonical use case: all hooks that previously checked ${CLAUDE_ROLE:-} now
# source this file and call resolve_role() instead so they respond to
# CLAUDE_ROLE (Claude Code) and PI_ROLE (PI harness) with a consistent
# precedence order.
#
# Precedence: CLAUDE_ROLE > PI_ROLE
# Returns the first non-empty value; exits 0 with empty stdout when all unset.
#
# Valid role values: debug, shape, refactor, ops (investigation/shaping/ops modes).
# Empty = plain orchestrator or build mode.
#
# Usage:
#   source "$(dirname "$0")/_role.sh"
#   role=$(resolve_role)
#   [ "$role" = "debug" ] && ...

set -u

resolve_role() {
    for v in "${CLAUDE_ROLE:-}" "${PI_ROLE:-}"; do
        [ -n "$v" ] && {
            printf '%s' "$v"
            return 0
        }
    done
    return 0
}
