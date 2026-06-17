#!/usr/bin/env bash
# worktree-remove-phoenix_test.sh — unit tests for worktree-remove-phoenix.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/worktree-remove-phoenix.sh"

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

# ── Temp workspace ────────────────────────────────────────────────────────────
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"

# Fake jq — field extraction using real WorktreeRemove schema
# Real schema: {"worktree_path": ".../.claude/worktrees/exp-slug", "cwd": "...", "hook_event_name": "WorktreeRemove"}
# NOTE: NO worktree_name in real schema — hook derives it via basename(worktree_path)
cat >"$BIN_DIR/jq" <<'FAKEJQ'
#!/bin/bash
INPUT=$(cat)
FILTER="$2"
case "$FILTER" in
  '.worktree_path // empty')
    python3 -c "import sys,json; d=json.load(sys.stdin); v=d.get('worktree_path'); print('' if v is None else v)" <<< "$INPUT" ;;
  '.cwd // empty')
    python3 -c "import sys,json; d=json.load(sys.stdin); v=d.get('cwd'); print('' if v is None else v)" <<< "$INPUT" ;;
  *) echo "" ;;
esac
FAKEJQ
chmod +x "$BIN_DIR/jq"

# ── Test 1: Happy path — deallocate_resources called with correct args ────────
DEALLOC_ARGS_FILE="$TMP_ROOT/dealloc_args"

STUB_RM="$TMP_ROOT/resource_manager.sh"
cat >"$STUB_RM" <<STUBRM
allocate_phoenix_port() { echo "4042"; }
deallocate_resources() {
    printf '%s %s' "\$1" "\$2" >"$DEALLOC_ARGS_FILE"
}
STUBRM

# Real schema: worktree_path present, worktree_name derived via basename
T1_INPUT='{"worktree_path":"/projects/myapp/.claude/worktrees/feat-x","cwd":"/projects/myapp","hook_event_name":"WorktreeRemove"}'
T1_EXIT=0
printf '%s' "$T1_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        CODEGEN_DIR="$TMP_ROOT" \
        bash "$HOOK" >/dev/null 2>&1 || T1_EXIT=$?

assert_eq "T1: exit 0 on happy path" "0" "$T1_EXIT"

if [ -f "$DEALLOC_ARGS_FILE" ]; then
    T1_ARGS=$(cat "$DEALLOC_ARGS_FILE")
    assert_eq "T1: deallocate_resources called with project + worktree_name derived from basename" "myapp feat-x" "$T1_ARGS"
else
    printf 'FAIL: T1: deallocate_resources was not called\n'
    fail=$((fail + 1))
fi

# ── Test 2: Missing worktree_path field — exits 0 (no-op) ────────────────────
DEALLOC_ARGS_FILE2="$TMP_ROOT/dealloc_args2"
STUB_RM2="$TMP_ROOT/resource_manager2.sh"
cat >"$STUB_RM2" <<STUBRM2
allocate_phoenix_port() { echo "4042"; }
deallocate_resources() {
    printf '%s %s' "\$1" "\$2" >"$DEALLOC_ARGS_FILE2"
}
STUBRM2

T2_INPUT='{"cwd":"/projects/myapp","hook_event_name":"WorktreeRemove"}'
T2_EXIT=0
printf '%s' "$T2_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        CODEGEN_DIR="$TMP_ROOT" \
        bash -c ". \"$STUB_RM2\"; bash \"$HOOK\"" >/dev/null 2>&1 || T2_EXIT=$?

assert_eq "T2: exit 0 when worktree_path missing" "0" "$T2_EXIT"

if [ ! -f "$DEALLOC_ARGS_FILE2" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T2: deallocate_resources NOT called when worktree_path missing\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T2: deallocate_resources was called despite missing worktree_path\n'
    fail=$((fail + 1))
fi

# ── Test 3: Missing cwd field — uses $PWD fallback, still calls deallocate ───
DEALLOC_ARGS_FILE3="$TMP_ROOT/dealloc_args3"
# Hook sources $CODEGEN_DIR/resource_manager.sh directly — write stub there
STUB_RM_T3="$TMP_ROOT/resource_manager_t3"
mkdir -p "$STUB_RM_T3"
cat >"$STUB_RM_T3/resource_manager.sh" <<STUBRM3
allocate_phoenix_port() { echo "4042"; }
deallocate_resources() {
    printf '%s %s' "\$1" "\$2" >"$DEALLOC_ARGS_FILE3"
}
STUBRM3

T3_INPUT='{"worktree_path":"/projects/otherapp/.claude/worktrees/feat-x","hook_event_name":"WorktreeRemove"}'
T3_EXIT=0
printf '%s' "$T3_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        CODEGEN_DIR="$STUB_RM_T3" \
        bash -c "cd /tmp; bash \"$HOOK\"" >/dev/null 2>&1 || T3_EXIT=$?

assert_eq "T3: exit 0 when cwd missing (falls back to PWD)" "0" "$T3_EXIT"

if [ -f "$DEALLOC_ARGS_FILE3" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T3: deallocate_resources called despite missing cwd\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T3: deallocate_resources not called when cwd missing\n'
    fail=$((fail + 1))
fi

# ── Test 4: Exit code always 0 (observe-only hook) ───────────────────────────
# Even when deallocate_resources fails, || true keeps exit 0.
# Hook sources $CODEGEN_DIR/resource_manager.sh — write fail stub there.
STUB_RM_T4="$TMP_ROOT/resource_manager_t4"
mkdir -p "$STUB_RM_T4"
cat >"$STUB_RM_T4/resource_manager.sh" <<'STUBRM4'
deallocate_resources() { return 1; }
STUBRM4

T4_INPUT='{"worktree_path":"/projects/otherapp/.claude/worktrees/feat-q","cwd":"/projects/otherapp","hook_event_name":"WorktreeRemove"}'
T4_EXIT=0
printf '%s' "$T4_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        CODEGEN_DIR="$STUB_RM_T4" \
        bash "$HOOK" >/dev/null 2>&1 || T4_EXIT=$?

assert_eq "T4: exit 0 even when deallocate_resources fails" "0" "$T4_EXIT"

# ── Test 5: worktree_name derived correctly from basename of worktree_path ────
DEALLOC_ARGS_FILE5="$TMP_ROOT/dealloc_args5"
# Hook sources $CODEGEN_DIR/resource_manager.sh directly — write stub there
STUB_RM_T5="$TMP_ROOT/resource_manager_t5"
mkdir -p "$STUB_RM_T5"
cat >"$STUB_RM_T5/resource_manager.sh" <<STUBRM5
allocate_phoenix_port() { echo "4042"; }
deallocate_resources() {
    printf '%s %s' "\$1" "\$2" >"$DEALLOC_ARGS_FILE5"
}
STUBRM5

T5_INPUT='{"worktree_path":"/some/repo/.claude/worktrees/my-feature-branch","cwd":"/some/repo","hook_event_name":"WorktreeRemove"}'
T5_EXIT=0
printf '%s' "$T5_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        CODEGEN_DIR="$STUB_RM_T5" \
        bash "$HOOK" >/dev/null 2>&1 || T5_EXIT=$?

assert_eq "T5: exit 0" "0" "$T5_EXIT"

if [ -f "$DEALLOC_ARGS_FILE5" ]; then
    T5_ARGS=$(cat "$DEALLOC_ARGS_FILE5")
    assert_eq "T5: basename extraction yields correct worktree_name" "repo my-feature-branch" "$T5_ARGS"
else
    printf 'FAIL: T5: deallocate_resources was not called\n'
    fail=$((fail + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
