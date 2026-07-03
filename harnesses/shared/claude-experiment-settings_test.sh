#!/usr/bin/env bash
# claude-experiment-settings_test.sh — static grep-sentinel test verifying
# both `claude` exec sites in claude-experiment.sh carry API_FORCE_IDLE_TIMEOUT
# via the shared SETTINGS_JSON var, forcing Claude Code's 5-min idle-stream
# abort. SETTINGS_JSON is assigned once (both branches of the interactive/
# non-interactive if) and referenced via `--settings "$SETTINGS_JSON"` at both
# exec sites, so co-location is var-level, not literal-line-level.
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

# (1) Exactly 2 lines assign SETTINGS_JSON carrying API_FORCE_IDLE_TIMEOUT (one
# per if/else branch of the interactive-detection block).
assign_cnt=$(grep -c 'SETTINGS_JSON=.*API_FORCE_IDLE_TIMEOUT' "$LAUNCHER")
check "(1) SETTINGS_JSON assigned with API_FORCE_IDLE_TIMEOUT exactly twice" "2" "$assign_cnt"

# (2) Every --settings exec-site line must reference the SETTINGS_JSON var
# (not a literal inline blob), and there must be exactly 2 such sites — one
# per `claude` exec (cold-start + normal).
settings_var_cnt=$(grep -c -- '--settings "\$SETTINGS_JSON"' "$LAUNCHER")
check "(2) both --settings exec sites reference \$SETTINGS_JSON" "2" "$settings_var_cnt"

# (3) Every --settings line (regardless of form) must be one of the
# var-referencing ones — i.e. no --settings line uses a literal inline blob.
settings_total_cnt=$(grep -c -- '--settings' "$LAUNCHER")
check "(3) no --settings line uses a literal inline blob" "$settings_total_cnt" "$settings_var_cnt"

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
