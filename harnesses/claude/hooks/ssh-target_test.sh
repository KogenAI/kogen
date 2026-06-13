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
#   T-new-1:  save_ssh_alias with login_user+operate_as → User + ops-operate-as lines
#   T-new-2:  save_ssh_alias with login_user only → User present, no ops-operate-as
#   T-new-3:  save_ssh_alias both empty → HostName-only (no User line)
#   T-new-4:  backfill_ssh_user on HostName-only alias → adds User + ops-operate-as
#   T-new-5:  backfill_ssh_user does NOT overwrite existing User line
#   T-new-6:  backfill_ssh_user idempotent — twice → one User line
#   T-new-7:  backfill_ssh_user leaves second Host block unmodified
#   T-new-8:  resolve_ssh_target HIT with no User → backfill → exports LOGIN_USER
#   T-new-9:  resolve_ssh_target MISS → exports LOGIN_USER and OPERATE_AS
#   T-new-10: under SSH_TARGET_NON_INTERACTIVE=1 MISS → no prompts, HostName-only
#   T-new-11: resolve_ssh_target HIT → exports OPS_ALIAS == candidate
#   T-new-12: resolve_ssh_target MISS-save (bare IP) → exports OPS_ALIAS == candidate
#   T-new-13: resolve_ssh_target MISS-existing (typed alias) → exports OPS_ALIAS == typed alias

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
    save_ssh_alias 'myapp-prod' '10.0.0.5' 'claude-ops' >/dev/null
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
    save_ssh_alias 'myapp-prod' '10.0.0.99' 'claude-ops' >/dev/null 2>&1 || true
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
result=$(HOME="$tmp" SSH_TARGET_NON_INTERACTIVE=1 bash -c "
    source '$HELPER'
    git() { echo '/fake/testproject'; }
    export -f git
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
result=$(HOME="$tmp" SSH_TARGET_NON_INTERACTIVE=1 bash -c "
    source '$HELPER'
    git() { echo '/fake/testproject'; }
    export -f git
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
result=$(HOME="$tmp" SSH_TARGET_NON_INTERACTIVE=1 bash -c "
    source '$HELPER'
    git() { echo '/fake/testproject'; }
    export -f git
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
result=$(HOME="$tmp" SSH_TARGET_NON_INTERACTIVE=1 bash -c "
    source '$HELPER'
    git() { echo '/fake/testproject'; }
    export -f git
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
result=$(HOME="$tmp" SSH_TARGET_NON_INTERACTIVE=1 bash -c "
    source '$HELPER'
    git() { echo '/fake/testproject'; }
    export -f git
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
    git() { echo '/fake/testproject'; }
    export -f git
    resolve_ssh_target 'prod' 'OPS' 'test-launcher' 2>/dev/null
" || exit_code=$?
assert_eq "non-interactive miss exits 1" "1" "$exit_code"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-1: save_ssh_alias with login_user+operate_as → User + ops-operate-as
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    save_ssh_alias 'myapp-prod' '10.0.0.5' 'claude-ops' 'root' 'dashboard' >/dev/null
    grep -c '    User root\|    # ops-operate-as: dashboard' ~/.ssh/config
")
assert_eq "save_ssh_alias login+operate_as writes both lines" "2" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-2: save_ssh_alias with login_user only → User present, no ops-operate-as
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    save_ssh_alias 'myapp-prod' '10.0.0.5' 'claude-ops' 'root' '' >/dev/null
    user_lines=\$(grep -c '    User root' ~/.ssh/config || true)
    ops_lines=\$(grep -c 'ops-operate-as' ~/.ssh/config || true)
    echo \"\${user_lines}|\${ops_lines}\"
")
assert_eq "save_ssh_alias login_user only: User present, no ops-operate-as" "1|0" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-3: save_ssh_alias both empty → HostName-only (no User line)
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    save_ssh_alias 'myapp-prod' '10.0.0.5' 'claude-ops' '' '' >/dev/null
    user_lines=\$(grep -c '    User ' ~/.ssh/config || true)
    echo \"\${user_lines}\"
")
assert_eq "save_ssh_alias both empty: no User line" "0" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-4: backfill_ssh_user on HostName-only alias → adds User + ops-operate-as
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host myapp-prod
    HostName 10.0.0.5
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    printf 'root\ndashboard\n' | backfill_ssh_user 'myapp-prod' ~/.ssh/config
    user_line=\$(grep '    User root' ~/.ssh/config || true)
    ops_line=\$(grep '    # ops-operate-as: dashboard' ~/.ssh/config || true)
    hostname_line=\$(grep '    HostName 10.0.0.5' ~/.ssh/config || true)
    echo \"\${user_line}|\${ops_line}|\${hostname_line}\"
")
assert_eq "backfill_ssh_user adds User + ops-operate-as, preserves HostName" \
    "    User root|    # ops-operate-as: dashboard|    HostName 10.0.0.5" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-5: backfill_ssh_user does NOT overwrite existing User line
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host myapp-prod
    HostName 10.0.0.5
    User existinguser
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    printf 'newuser\n\n' | backfill_ssh_user 'myapp-prod' ~/.ssh/config
    grep '    User ' ~/.ssh/config
")
assert_eq "backfill_ssh_user does not overwrite existing User" "    User existinguser" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-6: backfill_ssh_user idempotent — running twice → one User line
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host myapp-prod
    HostName 10.0.0.5
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    printf 'root\n\n' | backfill_ssh_user 'myapp-prod' ~/.ssh/config
    printf 'root\n\n' | backfill_ssh_user 'myapp-prod' ~/.ssh/config
    grep -c '    User root' ~/.ssh/config
")
assert_eq "backfill_ssh_user idempotent: one User line after two runs" "1" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-7: backfill_ssh_user leaves second Host block unmodified
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host myapp-prod
    HostName 10.0.0.5

Host myapp-stage
    HostName 10.0.0.6
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    printf 'root\n\n' | backfill_ssh_user 'myapp-prod' ~/.ssh/config
    # stage block should have no User line
    stage_user=\$(awk '/^Host myapp-stage/{f=1;next} f && /^Host /{f=0} f && /User /{print}' ~/.ssh/config || true)
    echo \"[\${stage_user}]\"
")
assert_eq "backfill_ssh_user leaves second block unmodified" "[]" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-8: resolve_ssh_target HIT with no User → backfill → config updated
# ──────────────────────────────────────────────────────────────────
# Pipe stdin for backfill prompts: login_user, operate_as
tmp=$(setup_home "Host testproject-prod
    HostName 10.0.0.1
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    git() { echo '/fake/testproject'; }
    export -f git
    ssh() { printf 'hostname 10.0.0.1\n'; }
    export -f ssh
    printf 'root\ndashboard\n' | resolve_ssh_target 'prod' 'OPS' 'test-launcher' >/dev/null 2>&1 || true
    user_line=\$(grep '    User root' ~/.ssh/config || true)
    ops_line=\$(grep '    # ops-operate-as: dashboard' ~/.ssh/config || true)
    echo \"\${user_line}|\${ops_line}\"
")
assert_eq "resolve HIT no-User → backfill writes User + ops-operate-as to config" \
    "    User root|    # ops-operate-as: dashboard" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-9: resolve_ssh_target MISS → saves alias with User + ops-operate-as in config
# ──────────────────────────────────────────────────────────────────
# Pipe stdin: alias input (1.2.3.4), login user (root), operate-as (dashboard)
# verify config was written with both User and ops-operate-as lines.
tmp=$(setup_home "")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    ssh() { printf 'hostname 1.2.3.4\n'; }
    export -f ssh
    git() { echo '/fake/testproject'; }
    export -f git
    # stdin: alias, login_user, operate_as
    printf '1.2.3.4\nroot\ndashboard\n' | resolve_ssh_target 'prod' 'OPS' 'test-launcher' >/dev/null 2>&1 || true
    user_line=\$(grep '    User root' ~/.ssh/config || true)
    ops_line=\$(grep '    # ops-operate-as: dashboard' ~/.ssh/config || true)
    echo \"\${user_line}|\${ops_line}\"
")
assert_eq "resolve MISS → config has User + ops-operate-as" \
    "    User root|    # ops-operate-as: dashboard" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-10: SSH_TARGET_NON_INTERACTIVE MISS → HostName-only (no User in saved block)
# ──────────────────────────────────────────────────────────────────
# Non-interactive MISS exits 1 immediately — so we test the save path directly.
# save_ssh_alias with no login_user/operate_as (non-interactive default) → HostName-only
tmp=$(setup_home "")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    SSH_TARGET_NON_INTERACTIVE=1 save_ssh_alias 'myapp-prod' '10.0.0.5' 'claude-ops' >/dev/null
    user_lines=\$(grep -c '    User ' ~/.ssh/config || true)
    hostname_lines=\$(grep -c '    HostName ' ~/.ssh/config || true)
    echo \"\${user_lines}|\${hostname_lines}\"
")
assert_eq "non-interactive save: HostName-only, no User line" "0|1" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-11: resolve_ssh_target HIT → OPS_ALIAS == candidate
# ──────────────────────────────────────────────────────────────────
tmp=$(setup_home "Host testproject-prod
    HostName 10.0.0.10
")
result=$(HOME="$tmp" SSH_TARGET_NON_INTERACTIVE=1 bash -c "
    source '$HELPER'
    git() { echo '/fake/testproject'; }
    export -f git
    ssh() { printf 'hostname 10.0.0.10\n'; }
    export -f ssh
    resolve_ssh_target 'prod' 'OPS' 'test-launcher'
    echo \"\${OPS_ALIAS}\"
")
assert_eq "T-new-11: HIT exports OPS_ALIAS == candidate" "testproject-prod" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-12: resolve_ssh_target MISS-save (bare IP) → OPS_ALIAS == candidate
# ──────────────────────────────────────────────────────────────────
# ssh -G on a bare IP echoes it back (server_resolved == user_alias) → save path.
# stdin via file redirect (not pipe) so exports propagate to outer bash -c shell.
tmp=$(setup_home "")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    git() { echo '/fake/testproject'; }
    export -f git
    ssh() {
        # ssh -G <arg> → echo 'hostname <arg>' to simulate bare-IP echo-back
        local arg=\"\$2\"
        printf 'hostname %s\n' \"\$arg\"
    }
    export -f ssh
    # stdin: alias input (1.2.3.4), login_user (root), operate-as (dashboard)
    stdin_file=\$(mktemp)
    printf '1.2.3.4\nroot\ndashboard\n' >\"\$stdin_file\"
    resolve_ssh_target 'prod' 'OPS' 'test-launcher' <\"\$stdin_file\" >/dev/null 2>&1 || true
    rm -f \"\$stdin_file\"
    echo \"\${OPS_ALIAS}\"
")
assert_eq "T-new-12: MISS-save exports OPS_ALIAS == candidate (testproject-prod)" "testproject-prod" "$result"
rm -rf "$tmp"

# ──────────────────────────────────────────────────────────────────
# T-new-13: resolve_ssh_target MISS-existing (typed alias) → OPS_ALIAS == user_alias
# ──────────────────────────────────────────────────────────────────
# Config has a different existing alias; candidate (testproject-prod) NOT in config.
# ssh -G existing-box returns a distinct hostname (5.6.7.8) → MISS-existing branch.
# stdin via file redirect (not pipe) so exports propagate.
tmp=$(setup_home "Host existing-box
    HostName 5.6.7.8
")
result=$(HOME="$tmp" bash -c "
    source '$HELPER'
    git() { echo '/fake/testproject'; }
    export -f git
    ssh() {
        # ssh -G existing-box → returns 5.6.7.8 (different from input → MISS-existing)
        printf 'hostname 5.6.7.8\n'
    }
    export -f ssh
    # stdin: typed alias (existing-box)
    stdin_file=\$(mktemp)
    printf 'existing-box\n' >\"\$stdin_file\"
    resolve_ssh_target 'prod' 'OPS' 'test-launcher' <\"\$stdin_file\" >/dev/null 2>&1 || true
    rm -f \"\$stdin_file\"
    echo \"\${OPS_ALIAS}\"
")
assert_eq "T-new-13: MISS-existing exports OPS_ALIAS == user_alias (existing-box)" "existing-box" "$result"
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
