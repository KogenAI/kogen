#!/usr/bin/env bash
# build-queue-continuity_test.sh — unit tests for build-queue-continuity.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/build-queue-continuity.sh"

pass=0
fail=0

assert_block() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected block\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
    fi
}

assert_allow() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        printf 'FAIL: %s — expected allow, got block\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    case "$haystack" in
    *"$needle"*)
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
        ;;
    *)
        printf 'FAIL: %s\n  expected to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
        ;;
    esac
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    case "$haystack" in
    *"$needle"*)
        printf 'FAIL: %s\n  expected NOT to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
        ;;
    *)
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
        ;;
    esac
}

make_project() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/codegen/gate-pending"
    mkdir -p "$dir/codegen/logging"
    printf '%s' "$dir"
}

mk_manifest() {
    # $1=project_dir $2=raw-json
    mkdir -p "$1/codegen/gate-pending"
    printf '%s' "$2" >"$1/codegen/gate-pending/build-queue.json"
}

mk_gate_result() {
    # $1=project_dir $2=verdict
    mkdir -p "$1/codegen/gate-pending"
    jq -n --arg v "$2" '{verdict:$v}' >"$1/codegen/gate-pending/gate-result.json"
}

mk_stop_input() {
    local cwd="$1"
    local stop_active="${2:-false}"
    jq -n \
        --arg c "$cwd" \
        --argjson sa "$stop_active" \
        '{"hook_event_name":"Stop","session_id":"test-sess","cwd":$c,"last_assistant_message":"Work complete.","stop_hook_active":$sa}'
}

# ── Test 1: block when manifest has remaining + gate verdict=clear ─────────────
T1=$(make_project)
mk_manifest "$T1" '{"slugs":["a","b","c"],"position":1,"started_at":"2026-01-01T00:00:00Z"}'
mk_gate_result "$T1" "clear"
out1=$(mk_stop_input "$T1" | env -u CLAUDE_ROLE bash "$HOOK" 2>/dev/null || true)
assert_block "block: manifest position=1 len=3 (2 remain) + gate=clear" "$out1"
rm -rf "$T1"

# ── Test 1B: shipped slug at manifest position is skipped in favor of next live slug ───
T1B=$(make_project)
mk_manifest "$T1B" '{"slugs":["a","b","c"],"position":1,"started_at":"2026-01-01T00:00:00Z"}'
mk_gate_result "$T1B" "clear"
mkdir -p "$T1B/codegen/pitches/shipped"
printf 'Pitch: b\n' >"$T1B/codegen/pitches/shipped/b.md"
out1b=$(mk_stop_input "$T1B" | env -u CLAUDE_ROLE bash "$HOOK" 2>/dev/null || true)
assert_block "block: shipped slug at position is skipped, next live slug blocks" "$out1b"
assert_not_contains "block: shipped slug is not nominated" "next: b" "$out1b"
assert_contains "block: next live slug nominated" "next: c" "$out1b"
rm -rf "$T1B"

# ── Test 2: allow when queue exhausted (position >= len) ──────────────────────
T2=$(make_project)
mk_manifest "$T2" '{"slugs":["a","b"],"position":2,"started_at":"2026-01-01T00:00:00Z"}'
mk_gate_result "$T2" "clear"
out2=$(mk_stop_input "$T2" | env -u CLAUDE_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: queue exhausted (position=2 len=2)" "$out2"
rm -rf "$T2"

# ── Test 3: allow when no manifest file ───────────────────────────────────────
T3=$(make_project)
out3=$(mk_stop_input "$T3" | env -u CLAUDE_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: no queue manifest (not a multi-pitch queue)" "$out3"
rm -rf "$T3"

# ── Test 4: allow when gate verdict=failed ────────────────────────────────────
T4=$(make_project)
mk_manifest "$T4" '{"slugs":["a","b","c"],"position":1,"started_at":"2026-01-01T00:00:00Z"}'
mk_gate_result "$T4" "failed"
out4=$(mk_stop_input "$T4" | env -u CLAUDE_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: gate verdict=failed — mid-queue halt" "$out4"
rm -rf "$T4"

# ── Test 5: allow when gate verdict=inconclusive ──────────────────────────────
T5=$(make_project)
mk_manifest "$T5" '{"slugs":["a","b","c"],"position":1,"started_at":"2026-01-01T00:00:00Z"}'
mk_gate_result "$T5" "inconclusive"
out5=$(mk_stop_input "$T5" | env -u CLAUDE_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: gate verdict=inconclusive — mid-queue halt" "$out5"
rm -rf "$T5"

# ── Test 6: allow when manifest is corrupt JSON ───────────────────────────────
T6=$(make_project)
mk_manifest "$T6" '{ not json at all'
out6=$(mk_stop_input "$T6" | env -u CLAUDE_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: corrupt manifest (fail-open)" "$out6"
rm -rf "$T6"

# ── Test 7: allow when manifest missing position key ─────────────────────────
T7=$(make_project)
mk_manifest "$T7" '{"slugs":["a","b"]}'
out7=$(mk_stop_input "$T7" | env -u CLAUDE_ROLE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: manifest missing position key (fail-open)" "$out7"
rm -rf "$T7"

# ── Test 8: block when manifest has remaining + NO gate-result.json ───────────
T8=$(make_project)
mk_manifest "$T8" '{"slugs":["a","b","c"],"position":0,"started_at":"2026-01-01T00:00:00Z"}'
# No gate-result.json → empty verdict → not failed → should block
out8=$(mk_stop_input "$T8" | env -u CLAUDE_ROLE bash "$HOOK" 2>/dev/null || true)
assert_block "block: manifest position=0 len=3 + no gate-result.json (empty verdict)" "$out8"
rm -rf "$T8"

# ── Test 9: allow when STOP_HOOK_ACTIVE=true (loop guard) ─────────────────────
T9=$(make_project)
mk_manifest "$T9" '{"slugs":["a","b","c"],"position":1,"started_at":"2026-01-01T00:00:00Z"}'
mk_gate_result "$T9" "clear"
out9=$(mk_stop_input "$T9" true | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: STOP_HOOK_ACTIVE=true (loop guard)" "$out9"
rm -rf "$T9"

# ── Test 10: skip when CLAUDE_ROLE=shape (investigative mode) ──────────────────
T10=$(make_project)
mk_manifest "$T10" '{"slugs":["a","b","c"],"position":1,"started_at":"2026-01-01T00:00:00Z"}'
mk_gate_result "$T10" "clear"
out10=$(mk_stop_input "$T10" | CLAUDE_ROLE=shape bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: CLAUDE_ROLE=shape — investigative skip (would block in build mode)" "$out10"
rm -rf "$T10"

# ── Test 11: build mode (role unset) still blocks — behavior unchanged ─────────
T11=$(make_project)
mk_manifest "$T11" '{"slugs":["a","b","c"],"position":1,"started_at":"2026-01-01T00:00:00Z"}'
mk_gate_result "$T11" "clear"
out11=$(mk_stop_input "$T11" | env -u CLAUDE_ROLE bash "$HOOK" 2>/dev/null || true)
assert_block "block: role unset (build mode) — gate unchanged" "$out11"
rm -rf "$T11"

# ── Test 12: CLAUDE_ROLE=build still blocks (explicit build role, not just empty) ──
T12=$(make_project)
mk_manifest "$T12" '{"slugs":["a","b","c"],"position":1,"started_at":"2026-01-01T00:00:00Z"}'
mk_gate_result "$T12" "clear"
out12=$(mk_stop_input "$T12" | CLAUDE_ROLE=build bash "$HOOK" 2>/dev/null || true)
assert_block "block: CLAUDE_ROLE=build — explicit build role still enforces" "$out12"
rm -rf "$T12"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
