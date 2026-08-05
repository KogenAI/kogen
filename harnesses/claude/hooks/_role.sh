#!/bin/bash
# _role.sh — shared helper: resolve the active role across harnesses.
#
# NOT a registered hook — this is a library helper sourced by hook scripts.
# Prefix "_" prevents hook_registrations.py from registering it.
# Canonical use case: all hooks that previously checked ${CLAUDE_ROLE:-} now
# source this file and call resolve_role() instead, so role resolution has a
# single definition. Kept as a helper (rather than inlining the env read) so a
# future second harness adds its variable here and nowhere else.
#
# Returns CLAUDE_ROLE when set; exits 0 with empty stdout when it is unset.
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
    [ -n "${CLAUDE_ROLE:-}" ] && printf '%s' "$CLAUDE_ROLE"
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
