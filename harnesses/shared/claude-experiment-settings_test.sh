#!/usr/bin/env bash
# claude-experiment-settings_test.sh — static grep-sentinel test verifying
# both `claude` exec sites in claude-experiment.sh carry API_FORCE_IDLE_TIMEOUT
# in their inline --settings env, forcing Claude Code's 5-min idle-stream abort.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$SCRIPT_DIR/../claude/claude-experiment.sh"

pass=0
fail=0

check() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

if [[ ! -f "$LAUNCHER" ]]; then
    printf 'FAIL: launcher not found at %s\n' "$LAUNCHER"
    printf '\nResults: %d passed, %d failed\n' "$pass" "$((fail + 1))"
    exit 1
fi

# (1) Exactly 2 lines total carry API_FORCE_IDLE_TIMEOUT (one per exec site).
total_cnt=$(grep -c 'API_FORCE_IDLE_TIMEOUT' "$LAUNCHER")
check "(1) API_FORCE_IDLE_TIMEOUT appears exactly twice" "2" "$total_cnt"

# (2) Co-location: every --settings line must carry the key, and the count of
# such co-located lines must also be 2 — proves the key sits INSIDE the
# --settings env blob at both exec sites, not a stray unrelated hit elsewhere.
settings_with_key_cnt=$(grep -c -- '--settings.*API_FORCE_IDLE_TIMEOUT' "$LAUNCHER")
check "(2) both --settings lines carry the key (co-located)" "2" "$settings_with_key_cnt"

# (3) Every --settings line (regardless of key) must be one of the co-located
# ones — i.e. no --settings line lacks the key.
settings_total_cnt=$(grep -c -- '--settings' "$LAUNCHER")
check "(3) no --settings line is missing the key" "$settings_total_cnt" "$settings_with_key_cnt"

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
