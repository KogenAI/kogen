#!/usr/bin/env bash
# worktree-create-phoenix_test.sh — unit tests for worktree-create-phoenix.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/worktree-create-phoenix.sh"

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
# Canonicalize: macOS /var is a symlink to /private/var; pwd -P in hook resolves it.
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"

# Fake jq — returns JSON field values from our fixtures using real schema
cat >"$BIN_DIR/jq" <<'FAKEJQ'
#!/bin/bash
INPUT=$(cat)
FILTER="$2"
case "$FILTER" in
  '.name // .worktreeName // .worktree_name // empty')
    python3 -c "
import sys, json
d = json.load(sys.stdin)
v = d.get('name') or d.get('worktreeName') or d.get('worktree_name')
print('' if v is None else v)
" <<< "$INPUT" ;;
  '.cwd // empty')
    python3 -c "import sys,json; d=json.load(sys.stdin); v=d.get('cwd'); print('' if v is None else v)" <<< "$INPUT" ;;
  *) echo "" ;;
esac
FAKEJQ
chmod +x "$BIN_DIR/jq"

# Fake mix — no-op
cat >"$BIN_DIR/mix" <<'FAKEMIX'
#!/bin/bash
exit 0
FAKEMIX
chmod +x "$BIN_DIR/mix"

# Stub resource_manager.sh
STUB_RM="$TMP_ROOT/resource_manager.sh"
cat >"$STUB_RM" <<'STUBRM'
LAST_ALLOCATE_ARGS=""
allocate_phoenix_port() {
    LAST_ALLOCATE_ARGS="$1 $2"
    echo "4042"
}
deallocate_resources() { true; }
STUBRM

# ── Test 1: Phoenix stack — deps symlink + _build copied + PORT appended ─────
# Real schema: {"name":"exp-test","cwd":"...","session_id":"...","hook_event_name":"WorktreeCreate"}
T1_CWD="$TMP_ROOT/t1_cwd"
T1_WT="$T1_CWD/.claude/worktrees/feat-x"
mkdir -p "$T1_CWD/deps" "$T1_CWD/_build"
touch "$T1_CWD/mix.exs" "$T1_CWD/.env"
printf 'DB_URL=postgres://localhost/myapp\nAPI_KEY=secret\n' >"$T1_CWD/.env"

FAKE_GIT_T1="$TMP_ROOT/git_t1"
cat >"$FAKE_GIT_T1" <<FAKEGIT
#!/bin/bash
# git -C <cwd> worktree add -b <branch> <path> <ref>  OR
# git -C <cwd> rev-parse <ref>
if [[ "\$*" == *"worktree list"* ]]; then exit 0; fi
if [[ "\$*" == *"show-ref"* ]]; then exit 1; fi
if [[ "\$*" == *"worktree add"* ]]; then
    mkdir -p "$T1_WT"
    exit 0
fi
# rev-parse HEAD or ref → same SHA (same-commit case)
echo "abc123sha"
FAKEGIT
chmod +x "$FAKE_GIT_T1"

T1_INPUT=$(printf '{"name":"feat-x","cwd":"%s","session_id":"sess-1","hook_event_name":"WorktreeCreate"}' "$T1_CWD")
T1_OUT=$(printf '%s' "$T1_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        bash -c "PATH=\"$BIN_DIR:$PATH\"; export PATH; . \"$STUB_RM\"; \
        git() { bash \"$FAKE_GIT_T1\" \"\$@\"; }; export -f git; \
        CODEGEN_DIR=\"$TMP_ROOT\" bash \"$HOOK\"" 2>/dev/null || true)

# stdout should be the constructed worktree_path
assert_eq "T1: stdout is constructed worktree_path" "$T1_WT" "$T1_OUT"

# deps symlink should exist
if [ -L "$T1_WT/deps" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T1: deps symlink created\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T1: deps symlink not created\n'
    fail=$((fail + 1))
fi

# _build copy should exist
if [ -d "$T1_WT/_build" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T1: _build copied\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T1: _build not copied\n'
    fail=$((fail + 1))
fi

# PORT should be in .env
if [ -f "$T1_WT/.env" ] && grep -q '^PORT=' "$T1_WT/.env"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T1: PORT written to .env\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T1: PORT not in .env\n'
    fail=$((fail + 1))
fi

# ── Test 2: Non-phoenix stack (no mix.exs) — no seeding ──────────────────────
T2_CWD="$TMP_ROOT/t2_cwd"
T2_WT="$T2_CWD/.claude/worktrees/feat-y"
mkdir -p "$T2_CWD"
# No mix.exs → static/node stack

FAKE_GIT_T2="$TMP_ROOT/git_t2"
cat >"$FAKE_GIT_T2" <<FAKEGIT2
#!/bin/bash
if [[ "\$*" == *"worktree list"* ]]; then exit 0; fi
if [[ "\$*" == *"show-ref"* ]]; then exit 1; fi
if [[ "\$*" == *"worktree add"* ]]; then
    mkdir -p "$T2_WT"
    exit 0
fi
echo "abc123sha"
FAKEGIT2
chmod +x "$FAKE_GIT_T2"

T2_INPUT=$(printf '{"name":"feat-y","cwd":"%s","session_id":"sess-2","hook_event_name":"WorktreeCreate"}' "$T2_CWD")
T2_OUT=$(printf '%s' "$T2_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        bash -c "PATH=\"$BIN_DIR:$PATH\"; export PATH; \
        git() { bash \"$FAKE_GIT_T2\" \"\$@\"; }; export -f git; \
        CODEGEN_DIR=\"$TMP_ROOT\" bash \"$HOOK\"" 2>/dev/null || true)

assert_eq "T2: stdout is worktree_path (non-phoenix)" "$T2_WT" "$T2_OUT"

if [ ! -L "$T2_WT/deps" ] && [ ! -e "$T2_WT/deps" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T2: no deps symlink for non-phoenix\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T2: unexpected deps symlink in non-phoenix worktree\n'
    fail=$((fail + 1))
fi

if [ ! -d "$T2_WT/_build" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T2: no _build copy for non-phoenix\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T2: unexpected _build in non-phoenix worktree\n'
    fail=$((fail + 1))
fi

# ── Test 3: Same-commit guard fails — _build NOT copied ──────────────────────
# base_ref=HEAD always so this tests the absent-_build path
T3_CWD="$TMP_ROOT/t3_cwd"
T3_WT="$T3_CWD/.claude/worktrees/feat-z"
mkdir -p "$T3_CWD"
# No _build dir → cold compile message
touch "$T3_CWD/mix.exs"

FAKE_GIT_T3="$TMP_ROOT/git_t3"
cat >"$FAKE_GIT_T3" <<FAKEGIT3
#!/bin/bash
if [[ "\$*" == *"worktree list"* ]]; then exit 0; fi
if [[ "\$*" == *"show-ref"* ]]; then exit 1; fi
if [[ "\$*" == *"worktree add"* ]]; then
    mkdir -p "$T3_WT"
    exit 0
fi
# HEAD and HEAD^{commit} resolve to same SHA (base_ref=HEAD always)
echo "aaaa"
FAKEGIT3
chmod +x "$FAKE_GIT_T3"

T3_INPUT=$(printf '{"name":"feat-z","cwd":"%s","session_id":"sess-3","hook_event_name":"WorktreeCreate"}' "$T3_CWD")
T3_STDERR=$(printf '%s' "$T3_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        bash -c "PATH=\"$BIN_DIR:$PATH\"; export PATH; . \"$STUB_RM\"; \
        git() { bash \"$FAKE_GIT_T3\" \"\$@\"; }; export -f git; \
        CODEGEN_DIR=\"$TMP_ROOT\" bash \"$HOOK\" 2>&1 1>/dev/null" || true)

if printf '%s' "$T3_STDERR" | grep -q "cold compile"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T3: cold compile logged when _build absent\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T3: expected "cold compile" stderr, got: %s\n' "$T3_STDERR"
    fail=$((fail + 1))
fi

if [ ! -d "$T3_WT/_build" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T3: _build not copied when absent in parent\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T3: _build was unexpectedly present\n'
    fail=$((fail + 1))
fi

# ── Test 4: Env strip — PORT/PORT_TEST/MIX_*_PARTITION/API_URL stripped ───────
T4_CWD="$TMP_ROOT/t4_cwd"
T4_WT="$T4_CWD/.claude/worktrees/feat-w"
mkdir -p "$T4_CWD"
touch "$T4_CWD/mix.exs"
printf 'DB_URL=postgres://localhost/myapp\nPORT=4000\nPORT_TEST=5000\nMIX_DEV_PARTITION=main\nMIX_TEST_PARTITION=main\nAPI_URL=http://localhost\nSECRET=keepme\n' \
    >"$T4_CWD/.env"

FAKE_GIT_T4="$TMP_ROOT/git_t4"
cat >"$FAKE_GIT_T4" <<FAKEGIT4
#!/bin/bash
if [[ "\$*" == *"worktree list"* ]]; then exit 0; fi
if [[ "\$*" == *"show-ref"* ]]; then exit 1; fi
if [[ "\$*" == *"worktree add"* ]]; then
    mkdir -p "$T4_WT"
    exit 0
fi
echo "sameshasha"
FAKEGIT4
chmod +x "$FAKE_GIT_T4"

T4_INPUT=$(printf '{"name":"feat-w","cwd":"%s","session_id":"sess-4","hook_event_name":"WorktreeCreate"}' "$T4_CWD")
printf '%s' "$T4_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        bash -c "PATH=\"$BIN_DIR:$PATH\"; export PATH; . \"$STUB_RM\"; \
        git() { bash \"$FAKE_GIT_T4\" \"\$@\"; }; export -f git; \
        CODEGEN_DIR=\"$TMP_ROOT\" bash \"$HOOK\"" >/dev/null 2>&1 || true

# PORT/PORT_TEST/MIX_*_PARTITION/API_URL must not appear in the stripped copy
for var in PORT PORT_TEST MIX_DEV_PARTITION MIX_TEST_PARTITION API_URL; do
    if [ -f "$T4_WT/.env" ] && grep -qE "^${var}=" "$T4_WT/.env" 2>/dev/null; then
        # New PORT/MIX_* added by hook are expected — only check for original values
        val=$(grep "^${var}=" "$T4_WT/.env" | head -1 | cut -d= -f2)
        original_val=$(grep "^${var}=" "$T4_CWD/.env" 2>/dev/null | head -1 | cut -d= -f2 || echo "")
        if [ -n "$original_val" ] && [ "$val" = "$original_val" ]; then
            printf 'FAIL: T4: %s original value not stripped from .env\n' "$var"
            fail=$((fail + 1))
        else
            [ -n "${VERBOSE:-}" ] && printf 'PASS: T4: %s has new value (not original)\n' "$var"
            pass=$((pass + 1))
        fi
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: T4: %s not in stripped .env (added fresh by hook)\n' "$var"
        pass=$((pass + 1))
    fi
done

# SECRET= must be preserved
if [ -f "$T4_WT/.env" ] && grep -q '^SECRET=keepme' "$T4_WT/.env"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T4: SECRET preserved in stripped .env\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T4: SECRET not preserved in stripped .env\n'
    fail=$((fail + 1))
fi

# ── Test 5: stdout contract — exact worktree_path, exit 0 ────────────────────
T5_CWD="$TMP_ROOT/t5_cwd"
T5_WT="$T5_CWD/.claude/worktrees/feat-5"
mkdir -p "$T5_CWD"
# non-phoenix: no mix.exs

FAKE_GIT_T5="$TMP_ROOT/git_t5"
cat >"$FAKE_GIT_T5" <<FAKEGIT5
#!/bin/bash
if [[ "\$*" == *"worktree list"* ]]; then exit 0; fi
if [[ "\$*" == *"show-ref"* ]]; then exit 1; fi
if [[ "\$*" == *"worktree add"* ]]; then
    mkdir -p "$T5_WT"
    exit 0
fi
echo "sha5"
FAKEGIT5
chmod +x "$FAKE_GIT_T5"

T5_INPUT=$(printf '{"name":"feat-5","cwd":"%s","session_id":"sess-5","hook_event_name":"WorktreeCreate"}' "$T5_CWD")
T5_EXIT=0
T5_OUT=$(printf '%s' "$T5_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        bash -c "PATH=\"$BIN_DIR:$PATH\"; export PATH; \
        git() { bash \"$FAKE_GIT_T5\" \"\$@\"; }; export -f git; \
        CODEGEN_DIR=\"$TMP_ROOT\" bash \"$HOOK\"" 2>/dev/null) || T5_EXIT=$?

assert_eq "T5: exit 0" "0" "$T5_EXIT"
assert_eq "T5: stdout is exact worktree_path" "$T5_WT" "$T5_OUT"

# ── Test 6: git worktree add failure → non-zero exit ─────────────────────────
T6_CWD="$TMP_ROOT/t6_cwd"
T6_WT="$T6_CWD/.claude/worktrees/feat-6"
mkdir -p "$T6_CWD"

FAKE_GIT_T6="$TMP_ROOT/git_t6"
cat >"$FAKE_GIT_T6" <<'FAKEGIT6'
#!/bin/bash
if [[ "$*" == *"worktree list"* ]]; then exit 0; fi
if [[ "$*" == *"show-ref"* ]]; then exit 1; fi
if [[ "$*" == *"worktree add"* ]]; then
    echo "fatal: bad ref" >&2
    exit 128
fi
echo "sha6"
FAKEGIT6
chmod +x "$FAKE_GIT_T6"

T6_INPUT=$(printf '{"name":"feat-6","cwd":"%s","session_id":"sess-6","hook_event_name":"WorktreeCreate"}' "$T6_CWD")
T6_EXIT=0
printf '%s' "$T6_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        bash -c "PATH=\"$BIN_DIR:$PATH\"; export PATH; \
        git() { bash \"$FAKE_GIT_T6\" \"\$@\"; }; export -f git; \
        CODEGEN_DIR=\"$TMP_ROOT\" bash \"$HOOK\"" >/dev/null 2>/dev/null || T6_EXIT=$?

if [ "$T6_EXIT" -ne 0 ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T6: non-zero exit when git worktree add fails\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T6: expected non-zero exit on git failure, got 0\n'
    fail=$((fail + 1))
fi

# ── Test 7: missing cwd → falls back to $PWD, exits 0 ───────────────────────
T7_CWD="$TMP_ROOT/t7_cwd"
mkdir -p "$T7_CWD"
# non-phoenix: no mix.exs

FAKE_GIT_T7="$TMP_ROOT/git_t7"
cat >"$FAKE_GIT_T7" <<FAKEGIT7
#!/bin/bash
if [[ "\$*" == *"worktree list"* ]]; then exit 0; fi
if [[ "\$*" == *"show-ref"* ]]; then exit 1; fi
if [[ "\$*" == *"worktree add"* ]]; then
    # Extract the worktree path arg (4th positional after -C <cwd> worktree add -b <branch>)
    # Just create it wherever git would
    wt_path="\${7}"
    mkdir -p "\$wt_path"
    exit 0
fi
echo "sha7"
FAKEGIT7
chmod +x "$FAKE_GIT_T7"

# No cwd field — hook falls back to $PWD
T7_INPUT='{"name":"feat-7","session_id":"sess-7","hook_event_name":"WorktreeCreate"}'
T7_EXIT=0
T7_OUT=$(printf '%s' "$T7_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        bash -c "cd \"$T7_CWD\"; PATH=\"$BIN_DIR:$PATH\"; export PATH; \
        git() { bash \"$FAKE_GIT_T7\" \"\$@\"; }; export -f git; \
        CODEGEN_DIR=\"$TMP_ROOT\" bash \"$HOOK\"" 2>/dev/null) || T7_EXIT=$?

assert_eq "T7: exit 0 when cwd missing (falls back to PWD)" "0" "$T7_EXIT"

# Path should contain feat-7 (derived from PWD)
if printf '%s' "$T7_OUT" | grep -q 'feat-7'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T7: worktree path contains name when cwd fallback used\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T7: expected path with feat-7, got: %s\n' "$T7_OUT"
    fail=$((fail + 1))
fi

# ── Test 8: null/missing name → exit non-zero with error message ─────────────
T8_CWD="$TMP_ROOT/t8_cwd"
mkdir -p "$T8_CWD"

T8_INPUT=$(printf '{"cwd":"%s","session_id":"sess-8","hook_event_name":"WorktreeCreate"}' "$T8_CWD")
T8_EXIT=0
T8_STDERR=$(printf '%s' "$T8_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        bash -c "PATH=\"$BIN_DIR:$PATH\"; export PATH; \
        CODEGEN_DIR=\"$TMP_ROOT\" bash \"$HOOK\" 2>&1 1>/dev/null") || T8_EXIT=$?

if [ "$T8_EXIT" -ne 0 ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T8: non-zero exit when name is missing\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T8: expected non-zero exit when name is missing, got 0\n'
    fail=$((fail + 1))
fi

if printf '%s' "$T8_STDERR" | grep -q 'missing .name'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T8: error message emitted for missing name\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T8: expected error message for missing name, got: %s\n' "$T8_STDERR"
    fail=$((fail + 1))
fi

# ── Test 9: branch name uses worktree-<name> convention ──────────────────────
T9_CWD="$TMP_ROOT/t9_cwd"
T9_WT="$T9_CWD/.claude/worktrees/exp-slug"
mkdir -p "$T9_CWD"

BRANCH_USED_FILE="$TMP_ROOT/branch_used"
FAKE_GIT_T9="$TMP_ROOT/git_t9"
cat >"$FAKE_GIT_T9" <<FAKEGIT9
#!/bin/bash
if [[ "\$*" == *"worktree list"* ]]; then exit 0; fi
if [[ "\$*" == *"show-ref"* ]]; then exit 1; fi
if [[ "\$*" == *"worktree add"* ]]; then
    # Capture the branch arg (-b <branch>)
    for i in "\$@"; do
        if [[ "\$prev" == "-b" ]]; then
            printf '%s' "\$i" >"$BRANCH_USED_FILE"
        fi
        prev="\$i"
    done
    mkdir -p "$T9_WT"
    exit 0
fi
echo "sha9"
FAKEGIT9
chmod +x "$FAKE_GIT_T9"

T9_INPUT=$(printf '{"name":"exp-slug","cwd":"%s","session_id":"sess-9","hook_event_name":"WorktreeCreate"}' "$T9_CWD")
printf '%s' "$T9_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        bash -c "PATH=\"$BIN_DIR:$PATH\"; export PATH; \
        git() { bash \"$FAKE_GIT_T9\" \"\$@\"; }; export -f git; \
        CODEGEN_DIR=\"$TMP_ROOT\" bash \"$HOOK\"" >/dev/null 2>/dev/null || true

if [ -f "$BRANCH_USED_FILE" ]; then
    T9_BRANCH=$(cat "$BRANCH_USED_FILE")
    assert_eq "T9: branch is worktree-<name>" "worktree-exp-slug" "$T9_BRANCH"
else
    printf 'FAIL: T9: git worktree add was not called (branch not captured)\n'
    fail=$((fail + 1))
fi

# ── Test 10: Reuse — pre-registered worktree → skip add, fresh PORT ──────────
T10_CWD="$TMP_ROOT/t10_cwd"
T10_WT="$T10_CWD/.claude/worktrees/exp-resume"
mkdir -p "$T10_CWD" "$T10_WT"
touch "$T10_CWD/mix.exs"
# Pre-existing .env in the worktree with a stale port
printf 'PORT=4000\nSECRET=keepme\n' >"$T10_WT/.env"

ADD_CALLED="$TMP_ROOT/t10_add_called"

FAKE_GIT_T10="$TMP_ROOT/git_t10"
cat >"$FAKE_GIT_T10" <<FAKEGIT10
#!/bin/bash
if [[ "\$*" == *"worktree list"* ]]; then
    # Return the worktree as already registered (absolute path)
    printf 'worktree %s\nbranch refs/heads/worktree-exp-resume\n\n' "$T10_WT"
    exit 0
fi
if [[ "\$*" == *"show-ref"* ]]; then exit 1; fi
if [[ "\$*" == *"worktree add"* ]]; then
    touch "$ADD_CALLED"
    mkdir -p "$T10_WT"
    exit 0
fi
echo "sha10"
FAKEGIT10
chmod +x "$FAKE_GIT_T10"

T10_INPUT=$(printf '{"name":"exp-resume","cwd":"%s","session_id":"sess-10","hook_event_name":"WorktreeCreate"}' "$T10_CWD")
T10_EXIT=0
T10_OUT=$(printf '%s' "$T10_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        bash -c "PATH=\"$BIN_DIR:$PATH\"; export PATH; . \"$STUB_RM\"; \
        git() { bash \"$FAKE_GIT_T10\" \"\$@\"; }; export -f git; \
        CODEGEN_DIR=\"$TMP_ROOT\" bash \"$HOOK\"" 2>/dev/null) || T10_EXIT=$?

assert_eq "T10: exit 0 on reuse" "0" "$T10_EXIT"
assert_eq "T10: stdout is worktree_path on reuse" "$T10_WT" "$T10_OUT"

if [ ! -f "$ADD_CALLED" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T10: git worktree add skipped on reuse\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T10: git worktree add was called on reuse (should be skipped)\n'
    fail=$((fail + 1))
fi

if [ -f "$T10_WT/.env" ] && grep -q '^PORT=' "$T10_WT/.env"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T10: PORT written to .env on reuse\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T10: PORT not in .env on reuse\n'
    fail=$((fail + 1))
fi

# ── Test 11: Orphaned branch — branch exists, no worktree → add WITHOUT -b ───
T11_CWD="$TMP_ROOT/t11_cwd"
T11_WT="$T11_CWD/.claude/worktrees/exp-orphan"
mkdir -p "$T11_CWD"
# Non-phoenix (no mix.exs) to keep the test minimal

ADD_ARGS_FILE="$TMP_ROOT/t11_add_args"

FAKE_GIT_T11="$TMP_ROOT/git_t11"
cat >"$FAKE_GIT_T11" <<FAKEGIT11
#!/bin/bash
if [[ "\$*" == *"worktree list"* ]]; then exit 0; fi
if [[ "\$*" == *"show-ref"* ]]; then
    # Branch exists (orphaned)
    exit 0
fi
if [[ "\$*" == *"worktree add"* ]]; then
    # Record full args for assertion
    printf '%s' "\$*" >"$ADD_ARGS_FILE"
    mkdir -p "$T11_WT"
    exit 0
fi
echo "sha11"
FAKEGIT11
chmod +x "$FAKE_GIT_T11"

T11_INPUT=$(printf '{"name":"exp-orphan","cwd":"%s","session_id":"sess-11","hook_event_name":"WorktreeCreate"}' "$T11_CWD")
T11_EXIT=0
T11_OUT=$(printf '%s' "$T11_INPUT" |
    PATH="$BIN_DIR:$PATH" \
        bash -c "PATH=\"$BIN_DIR:$PATH\"; export PATH; \
        git() { bash \"$FAKE_GIT_T11\" \"\$@\"; }; export -f git; \
        CODEGEN_DIR=\"$TMP_ROOT\" bash \"$HOOK\"" 2>/dev/null) || T11_EXIT=$?

assert_eq "T11: exit 0 on orphaned branch attach" "0" "$T11_EXIT"
assert_eq "T11: stdout is worktree_path on orphaned attach" "$T11_WT" "$T11_OUT"

if [ -f "$ADD_ARGS_FILE" ]; then
    T11_ADD_ARGS=$(cat "$ADD_ARGS_FILE")
    # Must contain "worktree add"
    if printf '%s' "$T11_ADD_ARGS" | grep -q "worktree add"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: T11: git worktree add called for orphaned branch\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: T11: git worktree add not called for orphaned branch\n'
        fail=$((fail + 1))
    fi
    # Must NOT contain " -b "
    case "$T11_ADD_ARGS" in
    *" -b "*)
        printf 'FAIL: T11: git worktree add used -b flag for orphaned branch (should not)\n'
        fail=$((fail + 1))
        ;;
    *)
        [ -n "${VERBOSE:-}" ] && printf 'PASS: T11: git worktree add did not use -b for orphaned branch\n'
        pass=$((pass + 1))
        ;;
    esac
else
    printf 'FAIL: T11: git worktree add was not called for orphaned branch\n'
    fail=$((fail + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
