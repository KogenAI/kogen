#!/usr/bin/env bash
# build-ready_test.sh — unit tests for harnesses/shared/build-ready-currency.sh.
# Exercises check_install_currency in an isolated tmp git repo so the paid
# legs ($(MAKE) doctor / $(MAKE) test) never run in this test.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/build-ready-currency.sh"

pass=0
fail=0

check() {
    local desc="$1"
    local expected_rc="$2"
    local actual_rc="$3"
    if [ "$actual_rc" -eq "$expected_rc" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected rc %s, got %s\n' "$desc" "$expected_rc" "$actual_rc"
        fail=$((fail + 1))
    fi
}

if [ ! -f "$HELPER" ]; then
    printf 'FAIL: helper not found at %s\n' "$HELPER"
    printf '\nResults: %d passed, %d failed\n' "$pass" "$((fail + 1))"
    exit 1
fi

# shellcheck source=harnesses/shared/build-ready-currency.sh
source "$HELPER"

TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/shared/rules" "$REPO/shared/subagents" "$REPO/harnesses/claude/hooks" "$REPO/harnesses/shared" "$REPO/templates/generator"
echo "rule content" >"$REPO/shared/rules/one.md"
echo "subagent content" >"$REPO/shared/subagents/one.md.j2"
echo "manifest: claude" >"$REPO/harnesses/claude/manifest.yaml"
echo "hook content" >"$REPO/harnesses/claude/hooks/one.sh"
echo "gen content" >"$REPO/templates/generator/gen.py"
echo "claude-shape content" >"$REPO/harnesses/claude/claude-shape.sh"
echo "claude-experiment content" >"$REPO/harnesses/claude/claude-experiment.sh"
echo "selector content" >"$REPO/harnesses/shared/pitch-context-selector.sh"
echo "claude-build content" >"$REPO/harnesses/claude/claude-build.sh"
echo "claude dispatch content" >"$REPO/harnesses/claude/dispatch.sh"
echo "signal bridge content" >"$REPO/harnesses/shared/loop-signal-bridge.sh"

git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "test"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "initial"

STAMP="$TMP_ROOT/.ocg-install-stamp"

# --- Case 1: GREEN — freshly written stamp matches working tree ---
build_ready_write_stamp "$REPO" "$STAMP"
check_install_currency "$REPO" "$STAMP" >/dev/null 2>&1
check "(1) fresh stamp matches working tree — currency OK" 0 "$?"

# --- Case 2: RED — stamp absent ---
rm -f "$STAMP"
check_install_currency "$REPO" "$STAMP" >/dev/null 2>&1
check "(2) absent stamp — currency FAIL" 1 "$?"

# --- Case 3: RED — HEAD differs (stamp sha stale) ---
build_ready_write_stamp "$REPO" "$STAMP"
echo "more rule content" >"$REPO/shared/rules/two.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "second commit"
check_install_currency "$REPO" "$STAMP" >/dev/null 2>&1
check "(3) HEAD differs from stamped sha — currency FAIL" 1 "$?"

# --- Case 4: RED — same HEAD, source edited (working-tree content differs) ---
build_ready_write_stamp "$REPO" "$STAMP"
echo "edited without commit" >>"$REPO/shared/rules/two.md"
check_install_currency "$REPO" "$STAMP" >/dev/null 2>&1
check "(4) same HEAD but edited source — currency FAIL" 1 "$?"

# --- Case 5: determinism — hash formula stable across repeated runs ---
git -C "$REPO" checkout -q -- shared/rules/two.md
hash1="$(build_ready_content_hash "$REPO")"
hash2="$(build_ready_content_hash "$REPO")"
if [ "$hash1" = "$hash2" ] && [ -n "$hash1" ]; then
    check "(5) content hash deterministic across repeated runs" 0 0
else
    check "(5) content hash deterministic across repeated runs" 0 1
fi

# --- Case 6: RED — same HEAD, dirty launcher (copied-into-install source) ---
build_ready_write_stamp "$REPO" "$STAMP"
echo "edited launcher without commit" >>"$REPO/harnesses/claude/claude-shape.sh"
check_install_currency "$REPO" "$STAMP" >/dev/null 2>&1
check "(6) same HEAD but edited claude-shape.sh — currency FAIL" 1 "$?"
git -C "$REPO" checkout -q -- harnesses/claude/claude-shape.sh

# --- Case 7: RED — same HEAD, dirty selector helper (live-sourced source) ---
build_ready_write_stamp "$REPO" "$STAMP"
echo "edited selector without commit" >>"$REPO/harnesses/shared/pitch-context-selector.sh"
check_install_currency "$REPO" "$STAMP" >/dev/null 2>&1
check "(7) same HEAD but edited pitch-context-selector.sh — currency FAIL" 1 "$?"
git -C "$REPO" checkout -q -- harnesses/shared/pitch-context-selector.sh

# --- Case 8: RED — same HEAD, dirty claude-build.sh (copied-into-install queue launcher) ---
build_ready_write_stamp "$REPO" "$STAMP"
echo "edited claude-build without commit" >>"$REPO/harnesses/claude/claude-build.sh"
check_install_currency "$REPO" "$STAMP" >/dev/null 2>&1
check "(8) same HEAD but edited claude-build.sh — currency FAIL" 1 "$?"
git -C "$REPO" checkout -q -- harnesses/claude/claude-build.sh

# --- Case 10: RED — same HEAD, dirty claude dispatch.sh (live-sourced source) ---
build_ready_write_stamp "$REPO" "$STAMP"
echo "edited claude dispatch without commit" >>"$REPO/harnesses/claude/dispatch.sh"
check_install_currency "$REPO" "$STAMP" >/dev/null 2>&1
check "(10) same HEAD but edited claude dispatch.sh — currency FAIL" 1 "$?"
git -C "$REPO" checkout -q -- harnesses/claude/dispatch.sh

# --- Case 12: RED — same HEAD, dirty loop-signal-bridge.sh (live-sourced shared helper) ---
build_ready_write_stamp "$REPO" "$STAMP"
echo "edited signal bridge without commit" >>"$REPO/harnesses/shared/loop-signal-bridge.sh"
check_install_currency "$REPO" "$STAMP" >/dev/null 2>&1
check "(12) same HEAD but edited loop-signal-bridge.sh — currency FAIL" 1 "$?"
git -C "$REPO" checkout -q -- harnesses/shared/loop-signal-bridge.sh

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
