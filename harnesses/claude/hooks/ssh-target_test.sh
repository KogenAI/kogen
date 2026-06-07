#!/bin/bash
# ssh-target_test.sh — unit tests for harnesses/claude/ssh-target.sh
#
# Tests:
#   1:  host_defined hit (entry exists in config)
#   2:  host_defined miss (entry absent from config)
#   3:  save_ssh_alias writes block when candidate absent
#   4:  save_ssh_alias skips write (TOCTOU: candidate already exists)
#   5:  resolve_ssh_target — empty resolution → exit 1
#   6:  ENV_LABEL for prod arg
#   7:  ENV_LABEL for stage arg
#   8:  ENV_LABEL for unknown arg
#   9:  prefix export — OPS_SERVER and OPS_ENV set correctly
#   10: prefix export — DEBUG_SERVER and DEBUG_ENV set correctly
#   11: non-interactive miss → exit 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../ssh-target.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

# ──────────────────────────────────────────────────────────────────
# Helpers that run in a subshell with a temp ~/.ssh/config stub.
# ──────────────────────────────────────────────────────────────────

# Create an isolated HOME with a stub ~/.ssh/config
setup_home() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.ssh"
    chmod 700 "$tmpdir/.ssh"
    printf '%s' "$1" >"$tmpdir/.ssh/config"
    chmod 600 "$tmpdir/.ssh/config"
    echo "$tmpdir"
}

# ──────────────────────────────────────────────────────────────────
# Test 1: host_defined — hit
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host myapp-prod
    HostName 10.0.0.1
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    if host_defined 'myapp-prod'; then echo hit; else echo miss; fi
")
assert_eq "host_defined hit" "hit" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# Test 2: host_defined — miss
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host myapp-stage
    HostName 10.0.0.2
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    if host_defined 'myapp-prod'; then echo hit; else echo miss; fi
")
assert_eq "host_defined miss" "miss" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# Test 3: save_ssh_alias — writes block for absent candidate
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    save_ssh_alias 'myapp-prod' '10.0.0.5' 'claude-ops'
    grep 'Host myapp-prod' ~/.ssh/config
")
assert_eq "save_ssh_alias writes alias" "Host myapp-prod" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# Test 4: save_ssh_alias — skips write when candidate already present (TOCTOU)
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host myapp-prod
    HostName 10.0.0.1
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    save_ssh_alias 'myapp-prod' '10.0.0.99' 'claude-ops' 2>&1 || true
    # Should still have original HostName, not the new one
    grep 'HostName' ~/.ssh/config
")
assert_eq "save_ssh_alias skips on TOCTOU" "    HostName 10.0.0.1" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# Test 5: resolve_ssh_target — empty resolution → exit 1
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host myapp-prod
    HostName localhost
")
# Override ssh to return empty hostname, triggering the empty guard
exit_code=0
bash -c "
    source '$HELPER'
    ssh() { echo 'hostname '; }
    export -f ssh
    HOME='$tmp' resolve_ssh_target 'prod' 'OPS' 'test-launcher' 2>/dev/null
" || exit_code=$?
assert_eq "empty resolution exits 1" "1" "$exit_code"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# Test 6: ENV_LABEL — prod arg
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host testproject-prod
    HostName 10.0.0.1
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    # stub ssh -G to return a hostname
    ssh() { printf 'hostname 10.0.0.1\n'; }
    export -f ssh
    resolve_ssh_target 'prod' 'OPS' 'test-launcher'
    echo \"\$ENV_LABEL\"
")
assert_eq "ENV_LABEL prod" "PROD" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# Test 7: ENV_LABEL — stage arg
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host testproject-stage
    HostName 10.0.0.2
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    ssh() { printf 'hostname 10.0.0.2\n'; }
    export -f ssh
    resolve_ssh_target 'stage' 'OPS' 'test-launcher'
    echo \"\$ENV_LABEL\"
")
assert_eq "ENV_LABEL stage" "STAGE" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# Test 8: ENV_LABEL — unknown arg treated as PROD
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host testproject-worker
    HostName 10.0.0.3
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    ssh() { printf 'hostname 10.0.0.3\n'; }
    export -f ssh
    resolve_ssh_target 'worker' 'OPS' 'test-launcher'
    echo \"\$ENV_LABEL\"
")
assert_eq "ENV_LABEL unknown treated as PROD" "UNKNOWN (treated as PROD)" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# Test 9: prefix export — OPS_SERVER and OPS_ENV
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host testproject-prod
    HostName 10.0.0.10
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    ssh() { printf 'hostname 10.0.0.10\n'; }
    export -f ssh
    resolve_ssh_target 'prod' 'OPS' 'test-launcher'
    echo \"\${OPS_SERVER}|\${OPS_ENV}\"
")
assert_eq "OPS prefix exports" "10.0.0.10|PROD" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# Test 10: prefix export — DEBUG_SERVER and DEBUG_ENV
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host testproject-stage
    HostName 10.0.0.20
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    ssh() { printf 'hostname 10.0.0.20\n'; }
    export -f ssh
    resolve_ssh_target 'stage' 'DEBUG' 'test-launcher'
    echo \"\${DEBUG_SERVER}|\${DEBUG_ENV}\"
")
assert_eq "DEBUG prefix exports" "10.0.0.20|STAGE" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# Test 11: non-interactive miss → exit 1
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host otherproject-prod
    HostName 10.0.0.99
")
exit_code=0
HOME="$tmp" SSH_TARGET_NON_INTERACTIVE=1 bash -c "
    source '$HELPER'
    resolve_ssh_target 'prod' 'OPS' 'test-launcher' 2>/dev/null
" || exit_code=$?
assert_eq "non-interactive miss exits 1" "1" "$exit_code"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
