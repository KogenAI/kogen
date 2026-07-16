#!/bin/bash
# cycle-log-schema-parity_test.sh — verify cycle log event schema consistency.
#
# Enforces that shared/rules/_core/session-log.md's event enumeration
# (the prose union of all kinds `codegen-log` can emit) matches the
# EVENT_SCHEMA_JQ table inside the codegen-log binary itself. The table is
# the canonical source; the prose enumeration is the legal contract agents
# see. Divergence between them is fail-loud.
#
# Exit: 0 = all checks pass, 1 = parity failure (no events extracted, or
# mismatch between extracted and table kinds).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_CODEGEN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CODEGEN_LOG_BIN="$REAL_CODEGEN_ROOT/codegen-log"
SESSION_LOG_MD="$REAL_CODEGEN_ROOT/shared/rules/_core/session-log.md"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
        return 0
    else
        printf 'FAIL: %s\n' "$desc" >&2
        printf '  expected: %s\n' "$expected" >&2
        printf '  actual:   %s\n' "$actual" >&2
        fail=$((fail + 1))
        return 1
    fi
}

# Extract event kinds from codegen-log binary via --kinds (reads EVENT_SCHEMA_JQ).
binary_kinds="$("$CODEGEN_LOG_BIN" --kinds | sort -u)"

if [ -z "$binary_kinds" ]; then
    printf 'FAIL: codegen-log --kinds returned no output (EVENT_SCHEMA_JQ is empty or malformed)\n' >&2
    exit 1
fi

# Extract event kinds from session-log.md prose enumeration.
# Schema is in `:66-78`, each kind in a `{"ev":"<kind>",...}` line.
# Extracts the kind strings and sorts uniquely.
prose_kinds="$(grep -oE '\{"ev":"[a-z_]+"' "$SESSION_LOG_MD" | sed 's/.*:"//;s/"//' | sort -u)"

if [ -z "$prose_kinds" ]; then
    printf 'FAIL: session-log.md contains no {"ev":"..."} events (schema extraction failed)\n' >&2
    exit 1
fi

# Parity check: binary enumeration must equal prose enumeration.
binary_sorted="$(printf '%s' "$binary_kinds" | sort)"
prose_sorted="$(printf '%s' "$prose_kinds" | sort)"

if [ "$binary_sorted" != "$prose_sorted" ]; then
    printf 'FAIL: event kind mismatch between codegen-log --kinds and session-log.md\n' >&2
    printf 'In binary (codegen-log --kinds):\n' >&2
    printf '%s\n' "$binary_sorted" | sed 's/^/  + /' >&2
    printf 'In prose (session-log.md):\n' >&2
    printf '%s\n' "$prose_sorted" | sed 's/^/  + /' >&2
    printf '\nMissing from prose:' >&2
    comm -23 <(printf '%s' "$binary_sorted") <(printf '%s' "$prose_sorted") | sed 's/^/\n  - /' >&2
    printf '\nExtra in prose (should not exist):' >&2
    comm -13 <(printf '%s' "$binary_sorted") <(printf '%s' "$prose_sorted") | sed 's/^/\n  - /' >&2
    printf '\n' >&2
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

# Summary.
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && exit 0 || exit 1
