#!/usr/bin/env bash
# worktree-lifecycle_test.sh — unit tests for worktree-lifecycle.sh
# (folded from experiment-prune_test.sh; exercises worktree_destroy).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/worktree-lifecycle.sh"

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

# ── Fake git binary builder ───────────────────────────────────────────────────
# Usage: make_fake_git <call_log_file> <show_ref_exit>
# Records every invocation as "<subcommand> <args>" to <call_log_file>.
# show-ref returns <show_ref_exit>; all other subcommands return 0.
make_fake_git() {
    local call_log="$1"
    local show_ref_exit="$2"
    cat >"$BIN_DIR/git" <<FAKEGIT
#!/usr/bin/env bash
subcommand="\$1"
shift
printf '%s %s\n' "\$subcommand" "\$*" >>"$call_log"
case "\$subcommand" in
    show-ref) exit $show_ref_exit ;;
    *) exit 0 ;;
esac
FAKEGIT
    chmod +x "$BIN_DIR/git"
}

# ── Fake resource_manager.sh builder ─────────────────────────────────────────
# Usage: make_fake_resource_manager <codegen_dir> <dealloc_args_file>
# Writes resource_manager.sh into <codegen_dir>/resource_manager.sh
make_fake_resource_manager() {
    local codegen_dir="$1"
    local dealloc_args_file="$2"
    cat >"$codegen_dir/resource_manager.sh" <<FAKERM
deallocate_resources() {
    printf '%s %s' "\$1" "\$2" >"$dealloc_args_file"
}
FAKERM
}

# ── Fake worktree dir builder ─────────────────────────────────────────────────
make_wt_dir() {
    local base="$1"
    local slug="$2"
    mkdir -p "$base/.claude/worktrees/exp-${slug}"
}

# ── Test 1: Happy path — dir + branch exist, exit 0, summary printed, deallocate called ──
T1_ROOT="$TMP_ROOT/t1"
mkdir -p "$T1_ROOT"
T1_CODEGEN_DIR="$T1_ROOT/codegen"
mkdir -p "$T1_CODEGEN_DIR"
T1_GIT_LOG="$T1_ROOT/git.log"
T1_DEALLOC="$T1_ROOT/dealloc.args"
make_fake_git "$T1_GIT_LOG" "0" # show-ref → found (exit 0)
make_fake_resource_manager "$T1_CODEGEN_DIR" "$T1_DEALLOC"
make_wt_dir "$T1_ROOT" "my-exp"

T1_EXIT=0
T1_OUT=$(
    cd "$T1_ROOT"
    PATH="$BIN_DIR:$PATH" \
        CODEGEN_DIR="$T1_CODEGEN_DIR" \
        bash -c ". \"$HELPER\"; worktree_destroy my-exp"
) || T1_EXIT=$?

assert_eq "T1: exit 0 on happy path" "0" "$T1_EXIT"
assert_eq "T1: summary printed" "pruned exp-my-exp: worktree removed, branch deleted, port released" "$T1_OUT"

if [ -f "$T1_DEALLOC" ]; then
    T1_DEALLOC_ARGS=$(cat "$T1_DEALLOC")
    assert_eq "T1: deallocate_resources called with project + workspace" "t1 exp-my-exp" "$T1_DEALLOC_ARGS"
else
    printf 'FAIL: T1: deallocate_resources was not called\n'
    fail=$((fail + 1))
fi

# Verify git commands were recorded
if [ -f "$T1_GIT_LOG" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T1: git calls recorded\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T1: git call log missing\n'
    fail=$((fail + 1))
fi

# ── Test 2: Slug sanitization — exp-my-exp input → exp-my-exp target, NOT exp-exp-my-exp ──
T2_ROOT="$TMP_ROOT/t2"
mkdir -p "$T2_ROOT"
T2_CODEGEN_DIR="$T2_ROOT/codegen"
mkdir -p "$T2_CODEGEN_DIR"
T2_GIT_LOG="$T2_ROOT/git.log"
T2_DEALLOC="$T2_ROOT/dealloc.args"
make_fake_git "$T2_GIT_LOG" "0"
make_fake_resource_manager "$T2_CODEGEN_DIR" "$T2_DEALLOC"
make_wt_dir "$T2_ROOT" "my-exp" # dir is exp-my-exp, NOT exp-exp-my-exp

T2_EXIT=0
T2_OUT=$(
    cd "$T2_ROOT"
    PATH="$BIN_DIR:$PATH" \
        CODEGEN_DIR="$T2_CODEGEN_DIR" \
        bash -c ". \"$HELPER\"; worktree_destroy exp-my-exp" # note: pass with exp- prefix
) || T2_EXIT=$?

assert_eq "T2: exit 0 (sanitized slug resolves correctly)" "0" "$T2_EXIT"

if [ -f "$T2_DEALLOC" ]; then
    T2_DEALLOC_ARGS=$(cat "$T2_DEALLOC")
    assert_eq "T2: workspace key is exp-my-exp, not exp-exp-my-exp" "t2 exp-my-exp" "$T2_DEALLOC_ARGS"
else
    printf 'FAIL: T2: deallocate_resources was not called\n'
    fail=$((fail + 1))
fi

# ── Test 3: Not-found — no dir, show-ref exits 1 → exit 1, no calls ──────────
T3_ROOT="$TMP_ROOT/t3"
mkdir -p "$T3_ROOT"
T3_CODEGEN_DIR="$T3_ROOT/codegen"
mkdir -p "$T3_CODEGEN_DIR"
T3_GIT_LOG="$T3_ROOT/git.log"
T3_DEALLOC="$T3_ROOT/dealloc.args"
make_fake_git "$T3_GIT_LOG" "1" # show-ref → not found (exit 1)
make_fake_resource_manager "$T3_CODEGEN_DIR" "$T3_DEALLOC"
# No worktree dir created

T3_EXIT=0
T3_STDERR=$(
    cd "$T3_ROOT"
    PATH="$BIN_DIR:$PATH" \
        CODEGEN_DIR="$T3_CODEGEN_DIR" \
        bash -c ". \"$HELPER\"; worktree_destroy ghost" 2>&1 >/dev/null
) || T3_EXIT=$?

assert_eq "T3: exit 1 when not found" "1" "$T3_EXIT"
assert_eq "T3: stderr message correct" "no experiment 'exp-ghost' found" "$T3_STDERR"

# Verify git worktree remove and branch -D were NOT called
T3_GIT_CMDS=$(cat "$T3_GIT_LOG" 2>/dev/null || true)
case "$T3_GIT_CMDS" in
*"worktree remove"*)
    printf 'FAIL: T3: git worktree remove should not be called when not found\n'
    fail=$((fail + 1))
    ;;
*)
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T3: git worktree remove not called\n'
    pass=$((pass + 1))
    ;;
esac

if [ -f "$T3_DEALLOC" ]; then
    printf 'FAIL: T3: deallocate_resources should not be called when not found\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T3: deallocate_resources not called\n'
    pass=$((pass + 1))
fi

# ── Test 4: Dir gone but branch lingers — exit 0, reclaim still runs ─────────
T4_ROOT="$TMP_ROOT/t4"
mkdir -p "$T4_ROOT"
T4_CODEGEN_DIR="$T4_ROOT/codegen"
mkdir -p "$T4_CODEGEN_DIR"
T4_GIT_LOG="$T4_ROOT/git.log"
T4_DEALLOC="$T4_ROOT/dealloc.args"
make_fake_git "$T4_GIT_LOG" "0" # show-ref → branch exists (exit 0)
make_fake_resource_manager "$T4_CODEGEN_DIR" "$T4_DEALLOC"
# No worktree dir — dir is gone, branch lingers

T4_EXIT=0
T4_OUT=$(
    cd "$T4_ROOT"
    PATH="$BIN_DIR:$PATH" \
        CODEGEN_DIR="$T4_CODEGEN_DIR" \
        bash -c ". \"$HELPER\"; worktree_destroy lingering"
) || T4_EXIT=$?

assert_eq "T4: exit 0 when dir gone but branch lingers" "0" "$T4_EXIT"

if [ -f "$T4_DEALLOC" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T4: deallocate_resources called (idempotent reclaim)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: T4: deallocate_resources not called when branch still lingers\n'
    fail=$((fail + 1))
fi

# ── Test 5: Fail-open re-run — git worktree remove fails, still exits 0 ──────
T5_ROOT="$TMP_ROOT/t5"
mkdir -p "$T5_ROOT"
T5_CODEGEN_DIR="$T5_ROOT/codegen"
mkdir -p "$T5_CODEGEN_DIR"
T5_DEALLOC="$T5_ROOT/dealloc.args"

# Fake git where worktree remove returns non-zero (already gone)
cat >"$BIN_DIR/git" <<'FAKEGIT5'
#!/usr/bin/env bash
subcommand="$1"; shift
case "$subcommand" in
    show-ref) exit 0 ;;
    worktree)
        case "$1" in remove) exit 1 ;; *) exit 0 ;; esac ;;
    *) exit 0 ;;
esac
FAKEGIT5
chmod +x "$BIN_DIR/git"
make_fake_resource_manager "$T5_CODEGEN_DIR" "$T5_DEALLOC"
make_wt_dir "$T5_ROOT" "retry-me"

T5_EXIT=0
(
    cd "$T5_ROOT"
    PATH="$BIN_DIR:$PATH" \
        CODEGEN_DIR="$T5_CODEGEN_DIR" \
        bash -c ". \"$HELPER\"; worktree_destroy retry-me" >/dev/null 2>&1
) || T5_EXIT=$?

assert_eq "T5: exit 0 even when git worktree remove fails (fail-open)" "0" "$T5_EXIT"

# Restore clean fake git for subsequent tests
make_fake_git "$TMP_ROOT/unused.log" "0"

# ── Test 6: Exact port-release key — project=basename(PWD), workspace=exp-<slug> ──
T6_ROOT="$TMP_ROOT/t6"
mkdir -p "$T6_ROOT"
T6_CODEGEN_DIR="$T6_ROOT/codegen"
mkdir -p "$T6_CODEGEN_DIR"
T6_GIT_LOG="$T6_ROOT/git.log"
T6_DEALLOC="$T6_ROOT/dealloc.args"
make_fake_git "$T6_GIT_LOG" "0"
make_fake_resource_manager "$T6_CODEGEN_DIR" "$T6_DEALLOC"
make_wt_dir "$T6_ROOT" "port-slug"

T6_EXIT=0
(
    cd "$T6_ROOT"
    PATH="$BIN_DIR:$PATH" \
        CODEGEN_DIR="$T6_CODEGEN_DIR" \
        bash -c ". \"$HELPER\"; worktree_destroy port-slug" >/dev/null 2>&1
) || T6_EXIT=$?

assert_eq "T6: exit 0" "0" "$T6_EXIT"

if [ -f "$T6_DEALLOC" ]; then
    T6_ARGS=$(cat "$T6_DEALLOC")
    # project = basename($T6_ROOT) = "t6"; workspace = "exp-port-slug"
    assert_eq "T6: port key project=basename(PWD) workspace=exp-<slug>" "t6 exp-port-slug" "$T6_ARGS"
else
    printf 'FAIL: T6: deallocate_resources was not called\n'
    fail=$((fail + 1))
fi

# ── Test 7: Launcher --done missing slug → exit 2 ────────────────────────────
# Test via a minimal stub of claude-experiment.sh's --done branch logic
T7_SCRIPT="$TMP_ROOT/t7_launcher.sh"
cat >"$T7_SCRIPT" <<LAUNCHERSTUB
#!/usr/bin/env bash
set -euo pipefail
CODEGEN_DIR="$TMP_ROOT/unused_codegen"
export CODEGEN_DIR
if [[ "\${1:-}" == "--done" ]]; then
    if [[ -z "\${2:-}" ]]; then
        printf 'claude-experiment: --done requires a <slug>\n' >&2
        exit 2
    fi
    source "\$CODEGEN_DIR/harnesses/shared/worktree-lifecycle.sh"
    worktree_destroy "\$2"
    exit \$?
fi
printf 'launcher: no --done arg\n'
exit 0
LAUNCHERSTUB
chmod +x "$T7_SCRIPT"

T7_EXIT=0
bash "$T7_SCRIPT" --done 2>/dev/null || T7_EXIT=$?

assert_eq "T7: --done with no slug exits 2" "2" "$T7_EXIT"

# ── Test 8: worktree_create stub — exits 2, loud, not silent no-op ──────────
T8_EXIT=0
T8_STDERR=$(bash -c ". \"$HELPER\"; worktree_create" 2>&1 >/dev/null) || T8_EXIT=$?
assert_eq "T8: worktree_create exits 2 (not wired until S5)" "2" "$T8_EXIT"
assert_eq "T8: worktree_create stderr names S5" "worktree_create: not wired until S5 (pi-experiment --new)" "$T8_STDERR"

# ── Test 9: worktree_reattach stub — exits 2, loud, not silent no-op ────────
T9_EXIT=0
T9_STDERR=$(bash -c ". \"$HELPER\"; worktree_reattach" 2>&1 >/dev/null) || T9_EXIT=$?
assert_eq "T9: worktree_reattach exits 2 (not wired until S5)" "2" "$T9_EXIT"
assert_eq "T9: worktree_reattach stderr names S5" "worktree_reattach: not wired until S5 (pi-experiment --new)" "$T9_STDERR"

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
