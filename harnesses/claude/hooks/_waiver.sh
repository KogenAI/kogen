#!/bin/bash
# _waiver.sh — shared helper: is a guard waived for THIS invocation?
#
# NOT a registered hook — library helper sourced by hook scripts. The "_"
# prefix keeps hook_registrations.py from registering it.
#
# waived? <hook-id> returns 0 (waived) iff BOTH:
#   1. CODEGEN_WAIVED_GUARDS (loop-injected, developer role only) names the id
#      — proves the loop granted it, to this role, this spawn.
#   2. codegen/pitches/building/<slug>.md declares the id in `waives:`
#      — proves a promoted pitch asked for it.
# Belt and braces: the env carries role+spawn scope the file cannot; the file
# carries authorization the env cannot (a var can be stale or inherited).
#
# Anything absent, empty, unparseable, or a non-waivable registry entry →
# returns 1 (ENFORCE). Fail-safe, mirroring is_build_mode()'s posture.
#
# On a granted waiver, appends ev:waiver to the cycle log. That write is
# fail-loud-non-blocking: stderr on failure, never changes the verdict.

set -uo pipefail

_waiver_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || pwd -P
}

# _waiver_registry_allows — true iff registry.yaml marks <id> waivable: true.
# Scans the entry block: from the `id: <hook-id>` line to the next blank line.
_waiver_registry_allows() {
    local id="$1" root reg
    root="$(_waiver_repo_root)"
    reg="$root/shared/enforcement/registry.yaml"
    [ -f "$reg" ] || return 1
    awk -v want="$id" '
        $1=="id:" && $2==want { inblock=1; next }
        inblock && /^[[:space:]]*$/ { inblock=0 }
        inblock && $1=="waivable:" && $2=="true" { found=1; exit }
        END { exit(found ? 0 : 1) }
    ' "$reg" 2>/dev/null
}

# _waiver_pitch_declares — true iff the single building/<slug>.md declares <id>
# in its `waives:` flow-list. Zero or 2+ files → false.
_waiver_pitch_declares() {
    local id="$1" root count pitch line
    root="$(_waiver_repo_root)"
    count=$(find "$root/codegen/pitches/building" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" = "1" ] || return 1
    pitch=$(find "$root/codegen/pitches/building" -maxdepth 1 -name '*.md' 2>/dev/null)
    line=$(awk 'NR==1 && $0!="---" { exit } NR==1 { next } /^---$/ { exit } /^waives:/ { print; exit }' "$pitch" 2>/dev/null)
    [ -n "$line" ] || return 1
    printf '%s' "$line" |
        sed -e 's/^waives:[[:space:]]*//' -e 's/[][]//g' -e 's/,/\n/g' |
        tr -d ' ' | grep -qxF "$id"
}

# _waiver_record — append ev:waiver. Fail-loud-non-blocking.
_waiver_record() {
    local id="$1" role slug root
    root="$(_waiver_repo_root)"
    slug=$(find "$root/codegen/pitches/building" -maxdepth 1 -name '*.md' -exec basename {} .md \; 2>/dev/null | head -n 1)
    role=$(resolve_role)
    codegen-log append "$role" --waiver "$id" --waiver-slug "$slug" >/dev/null 2>&1 ||
        printf 'waiver: failed to record ev:waiver for %s (proceeding)\n' "$id" >&2
}

# waived? <hook-id> — 0 = waived (skip the deny), 1 = enforce.
waived?() {
    local id="$1"
    [ -n "${CODEGEN_WAIVED_GUARDS:-}" ] || return 1
    printf '%s' "${CODEGEN_WAIVED_GUARDS:-}" | tr ',' '\n' | tr -d ' ' | grep -qxF "$id" || return 1
    _waiver_registry_allows "$id" || return 1
    _waiver_pitch_declares "$id" || return 1
    _waiver_record "$id"
    return 0
}
