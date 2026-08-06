#!/usr/bin/env bash
# mix-build-path-parity.sh — one Mix build root, one MIX_ENV.
#
# `MIX_BUILD_PATH` overrides Mix's build path WHOLESALE: unlike the default
# `_build/<env>`, it does NOT get a per-environment subdirectory. So
# `MIX_BUILD_PATH=_build/claude_test` names ONE physical directory no matter
# which MIX_ENV the invocation runs under. Two invocations that name the same
# root under different environments therefore purge and recompile each other's
# beams on every alternation — and a purge that lands while another BEAM is
# lazily loading from that root is the `UndefinedFunctionError: module ... is
# not available` failure this repo documents at context/development.md
# § Mix build-path assignment.
#
# That invariant used to live only in a prose table a human had to remember to
# consult. This script derives the root -> MIX_ENV map from the source itself
# and fails when any root is claimed by more than one environment, so the
# invariant cannot silently drift again.
#
# Environment is derived per invocation site (backslash-continued lines are
# joined first, so a Makefile recipe that splits the assignment and the `mix`
# call across physical lines is read as the single command it is):
#   explicit `MIX_ENV=<x>` on the joined command  -> x
#   otherwise the command contains `mix test`     -> test
#   otherwise                                     -> dev
# (`mix test` forces MIX_ENV=test — Mix's own preferred-env behaviour.)
#
# Usage: mix-build-path-parity.sh [repo_root]
# Exit 0: every literal `_build/<root>` is claimed by exactly one MIX_ENV.
# Exit 1: a root is claimed by two or more; every offending site is printed.
set -uo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$repo_root" || exit 1

scan_awk='
function flush(   root, env, i) {
    if (buf !~ /MIX_BUILD_PATH=_build\//) { return }
    root = buf
    sub(/.*MIX_BUILD_PATH=_build\//, "", root)
    sub(/[^A-Za-z0-9_.-].*/, "", root)
    if (root == "") { return }
    if (buf ~ /MIX_ENV=[A-Za-z0-9_]+/) {
        env = buf
        sub(/.*MIX_ENV=/, "", env)
        sub(/[^A-Za-z0-9_].*/, "", env)
    } else if (buf ~ /mix[[:space:]]+test([[:space:]]|$)/) {
        env = "test"
    } else {
        env = "dev"
    }
    printf "%s\t%s\t%s:%d\n", root, env, FILENAME, start
}
{
    line = $0
    # A comment line is documentation, not an invocation site. Without this,
    # every prose mention of a build root — including the docstring above and
    # the codegen-drain header comment — is scanned as if it ran, and the
    # guard reports a conflict against itself.
    if (buf == "" && line ~ /^[[:space:]]*#/) { next }
    if (buf == "") { start = FNR }
    if (line ~ /\\$/) {
        sub(/\\$/, "", line)
        buf = buf line
        next
    }
    buf = buf line
    flush()
    buf = ""
}
END { if (buf != "") flush() }
'

sites=$(
    git ls-files -z 2>/dev/null |
        tr '\0' '\n' |
        grep -vE '^(node_modules|deps)/|/_build/' |
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            grep -q 'MIX_BUILD_PATH=_build/' "$f" 2>/dev/null && printf '%s\n' "$f"
        done |
        while IFS= read -r f; do
            awk "$scan_awk" "$f"
        done | sort -u
)

if [ -z "$sites" ]; then
    printf 'mix-build-path-parity: no MIX_BUILD_PATH=_build/<root> site found — the scan matched nothing, which cannot be right\n' >&2
    exit 1
fi

conflicts=$(
    printf '%s\n' "$sites" |
        awk -F'\t' '{ if (!((($1) SUBSEP ($2)) in seen)) { seen[($1) SUBSEP ($2)] = 1; n[$1]++ } }
                    END { for (r in n) if (n[r] > 1) print r }' |
        sort
)

if [ -z "$conflicts" ]; then
    if [ -n "${VERBOSE:-}" ]; then
        printf 'mix-build-path-parity: OK — %s site(s), one MIX_ENV per build root\n' \
            "$(printf '%s\n' "$sites" | wc -l | tr -d ' ')"
        printf '%s\n' "$sites" | awk -F'\t' '{printf "  _build/%-22s %-5s %s\n", $1, $2, $3}'
    fi
    exit 0
fi

printf '%s\n' "$conflicts" | while IFS= read -r root; do
    [ -z "$root" ] && continue
    printf 'mix-build-path-parity: _build/%s is claimed by more than one MIX_ENV — one build root, one env (MIX_BUILD_PATH has no per-env subdirectory, so these invocations purge and recompile each other):\n' "$root"
    printf '%s\n' "$sites" | awk -F'\t' -v r="$root" '$1 == r {printf "    MIX_ENV=%-5s %s\n", $2, $3}'
done
exit 1
