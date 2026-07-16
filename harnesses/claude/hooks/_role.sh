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
# is_build_mode() is the canonical build-cycle gate: the investigative set is
# {shape, debug, ops, experiment, refactor, babysit} — resolve_role() returning
# any of those means "skip" (investigative mode). build, empty, and any unknown
# role are fail-safe ACTIVE (guards run) — a build that ever loses its role
# still gets guarded.
#
# Usage:
#   source "$(dirname "$0")/_role.sh"
#   role=$(resolve_role)
#   [ "$role" = "debug" ] && ...
#   is_build_mode || exit 0   # skip in investigative modes

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

# is_build_mode — build-cycle gate. Returns 0 (active/enforce) for build,
# empty, and any unknown role; returns 1 (skip) only for named investigative
# modes. Fail-safe: a build that ever loses its role still gets guarded.
is_build_mode() {
    case "$(resolve_role)" in
    shape | debug | ops | experiment | refactor | babysit) return 1 ;;
    *) return 0 ;;
    esac
}
