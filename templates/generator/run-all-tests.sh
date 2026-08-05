#!/usr/bin/env bash
# run-all-tests.sh — the `make test` orchestrator, extracted from the
# Makefile `test:` recipe for reviewability/testability.
#
# Two-phase execution for a reproducible verdict under parallelism:
#
#   Phase 1 (broad, parallel): every independent parity/scaffold/install/npm
#   check + gate runs concurrently via & + wait, as before. Each *_test.sh is
#   hermetic — own tmp dirs, no shared state — so parallel is safe. Job count
#   is implicitly capped by the number of backgrounded stages (small; nested
#   runners cap their own internal fan-out at 8).
#
#   Phase 2 (serial isolation tail): hooks, test-hermetic, and
#   rule-render-freshness run ONE AT A TIME, after phase 1 fully joins.
#   These three are load-sensitive (hook test timing assumptions,
#   BEAM/ExUnit scheduler contention, prettier formatting under CPU
#   starvation) and previously produced load-dependent flakes when run
#   alongside 15+ other concurrent populations. Each tail population still
#   runs even if an earlier tail population failed — no fail-fast — so a
#   single `make test` still surfaces every independent failure.
#
#   Core-gated tail overlap: on a box with logical cores >=
#   TAIL_OVERLAP_MIN_CORES (default 6), the CPU-starvation cause of the old
#   flake is no longer present — there is core headroom to run hooks,
#   test-hermetic, and rule-render-freshness CONCURRENTLY with phase 1
#   instead of serially after it (measured: ~201s -> ~105s on a 10-core
#   box, green x4). Below the threshold (e.g. a 2-core box) the exact
#   serial tail above still runs, byte-for-byte, unchanged. The threshold
#   and the detected core count are both validated as positive integers in
#   1..1024 BEFORE the comparison is made — a malformed
#   TAIL_OVERLAP_MIN_CORES or an empty/failed core probe is a hard `exit 1`
#   naming the problem, never a silent fall-through to either branch. This
#   is deliberate: an unchecked `[ "$cores" -ge "$MIN" ]` can error-to-false
#   on garbage input and silently pick the serial branch, which is exactly
#   the defect this validation closes.
#
# One-owner execution: five harnesses/claude/hooks/*_test.sh files are ALSO
# invoked directly by harness-parity/prompt-content-parity
# in phase 1. HOOK_DEDUP_EXCLUDE lists those exact repo-relative paths and is
# passed as HOOK_TEST_EXCLUDE to the hooks tail population ONLY (never
# exported), so each discovered hook test runs exactly once per `make test`.
# Standalone `bash harnesses/claude/hooks/run-tests.sh` and
# `make test-coverage-shell` are untouched and still run the full population.
#
# Tracked-tree isolation backstop: a `git diff --binary --full-index HEAD --`
# snapshot is taken before phase 1 starts and after phase 2 joins. Any
# changed tracked byte, executable bit, symlink target, deletion, or
# restoration (relative to whatever the tree already looked like at entry)
# is a loud `tracked-tree-isolation` failure — a test suite must never mutate
# the source checkout it is validating. A pre-existing dirty tree at entry is
# allowed to stay exactly as dirty; only a suite-caused CHANGE to that state
# fails.
#
# The same backstop also snapshots `git status --porcelain --untracked-files=all`
# (entry vs exit) to catch a suite LEAKING a brand-new untracked path into the
# repo — e.g. a test helper that creates a symlink/file under the checkout
# and never cleans it up. This is the case the tracked-byte diff above is
# blind to: a new path is invisible to `git diff` until something later
# stages it. Deliberately WITHOUT `--ignored` — gitignored paths (codegen/,
# coverage/, tmp/, node_modules/) legitimately churn every run (cycle logs,
# coverage output, build artifacts) and must never fail this check. Only a
# suite-caused DELTA in the untracked set fails; a pre-existing untracked
# file that persists unchanged across the window is tolerated, same
# contract as the tracked-byte snapshot above.
set -e
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR"

# ── Core-gated tail overlap: fail-loud threshold validation ─────────────────
# Both TAIL_OVERLAP_MIN_CORES (operator-overridable) and the detected core
# count must be positive integers in 1..1024. A malformed or empty value on
# EITHER side is a named, immediate exit 1 — this validation runs BEFORE the
# `-ge` comparison so garbage input can never error-to-false and silently
# select the serial branch.
_validate_positive_int_1_1024() {
    local name="$1" val="$2"
    case "$val" in
    '' | *[!0-9]*)
        printf 'run-all-tests: %s must be a positive integer, got %q\n' "$name" "$val" >&2
        exit 1
        ;;
    esac
    if [ "$val" -lt 1 ] || [ "$val" -gt 1024 ]; then
        printf 'run-all-tests: %s must be in range 1..1024, got %q\n' "$name" "$val" >&2
        exit 1
    fi
}

TAIL_OVERLAP_MIN_CORES="${TAIL_OVERLAP_MIN_CORES:-6}"
_validate_positive_int_1_1024 "TAIL_OVERLAP_MIN_CORES" "$TAIL_OVERLAP_MIN_CORES"

cores=$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || true)
_validate_positive_int_1_1024 "detected core count" "$cores"

TAIL_OVERLAP=0
if [ "$cores" -ge "$TAIL_OVERLAP_MIN_CORES" ]; then
    TAIL_OVERLAP=1
fi

# Tracked-tree isolation backstop: snapshot entry state. A failed snapshot
# command is itself a loud failure (never falls back to an empty snapshot,
# which would silently disable the backstop).
tmp_tree_before=$(mktemp)
if ! git diff --binary --full-index HEAD -- >"$tmp_tree_before" 2>&1; then
    echo "tracked-tree-isolation: FAILED to capture entry snapshot"
    cat "$tmp_tree_before"
    rm -f "$tmp_tree_before"
    exit 1
fi

tmp_untracked_before=$(mktemp)
if ! git status --porcelain --untracked-files=all -- >"$tmp_untracked_before" 2>&1; then
    echo "tracked-tree-isolation: FAILED to capture untracked entry snapshot"
    cat "$tmp_untracked_before"
    rm -f "$tmp_tree_before" "$tmp_untracked_before"
    exit 1
fi

# ── Phase 1: broad parallel fan-out ─────────────────────────────────────────
tmp_scaffold=$(mktemp)
tmp_install=$(mktemp)
tmp_hook_parity=$(mktemp)
tmp_hook_header_parity=$(mktemp)
tmp_harness_parity=$(mktemp)
tmp_test_generator=$(mktemp)
tmp_enforce_registry_parity=$(mktemp)
tmp_enforce_hook_rationale=$(mktemp)
tmp_prompt_content_parity=$(mktemp)
tmp_usage_rules_index_parity=$(mktemp)
tmp_prompt_size_budget=$(mktemp)
tmp_pitch_scope_parity=$(mktemp)
# The three tail-population tmp files are mktemp'd unconditionally here (not
# inside the phase-2 block below) so cleanup at the end of the script is
# uniform regardless of which branch (overlap or serial) actually runs them.
tmp_hooks=$(mktemp)
tmp_test_hermetic=$(mktemp)
tmp_rule_render_freshness=$(mktemp)
pids=()
labels=()
tmps=()
HOOK_DEDUP_EXCLUDE="harnesses/claude/hooks/codegen-build_test.sh
harnesses/claude/hooks/codegen-call_test.sh
harnesses/claude/hooks/codegen-propose_test.sh
harnesses/claude/hooks/prompt-content-parity_test.sh"
{ ./shared/scaffold/phoenix/run-tests.sh; } >"$tmp_scaffold" 2>&1 &
pids+=($!)
labels+=(scaffold-phoenix)
tmps+=("$tmp_scaffold")
{ ./test_harness/install/run-tests.sh; } >"$tmp_install" 2>&1 &
pids+=($!)
labels+=(install)
tmps+=("$tmp_install")
{ make --no-print-directory hook-parity; } >"$tmp_hook_parity" 2>&1 &
pids+=($!)
labels+=(hook-parity)
tmps+=("$tmp_hook_parity")
{ make --no-print-directory hook-header-parity; } >"$tmp_hook_header_parity" 2>&1 &
pids+=($!)
labels+=(hook-header-parity)
tmps+=("$tmp_hook_header_parity")
{ make --no-print-directory harness-parity; } >"$tmp_harness_parity" 2>&1 &
pids+=($!)
labels+=(harness-parity)
tmps+=("$tmp_harness_parity")
{ make --no-print-directory test-generator; } >"$tmp_test_generator" 2>&1 &
pids+=($!)
labels+=(test-generator)
tmps+=("$tmp_test_generator")
{ make --no-print-directory enforce-registry-parity; } >"$tmp_enforce_registry_parity" 2>&1 &
pids+=($!)
labels+=(enforce-registry-parity)
tmps+=("$tmp_enforce_registry_parity")
{ make --no-print-directory enforce-hook-rationale; } >"$tmp_enforce_hook_rationale" 2>&1 &
pids+=($!)
labels+=(enforce-hook-rationale)
tmps+=("$tmp_enforce_hook_rationale")
{ make --no-print-directory prompt-content-parity; } >"$tmp_prompt_content_parity" 2>&1 &
pids+=($!)
labels+=(prompt-content-parity)
tmps+=("$tmp_prompt_content_parity")
{ make --no-print-directory usage-rules-index-parity; } >"$tmp_usage_rules_index_parity" 2>&1 &
pids+=($!)
labels+=(usage-rules-index-parity)
tmps+=("$tmp_usage_rules_index_parity")
{ make --no-print-directory prompt-size-budget; } >"$tmp_prompt_size_budget" 2>&1 &
pids+=($!)
labels+=(prompt-size-budget)
tmps+=("$tmp_prompt_size_budget")
{ make --no-print-directory pitch-scope-parity; } >"$tmp_pitch_scope_parity" 2>&1 &
pids+=($!)
labels+=(pitch-scope-parity)
tmps+=("$tmp_pitch_scope_parity")
tmp_mcp_server=$(mktemp)
{
    mcp_dir="$SCRIPT_DIR/harnesses/claude/mcp-server"
    fail=0
    if [ -f "$mcp_dir/package.json" ] && grep -q '"test"[[:space:]]*:' "$mcp_dir/package.json"; then
        if [ -n "$VERBOSE" ]; then
            echo "▶ Test: mcp-server"
            if ! (cd "$mcp_dir" && mise exec -- npm test); then
                fail=1
            fi
        else
            if ! out=$(cd "$mcp_dir" && mise exec -- npm test 2>&1); then
                echo "▶ Test: mcp-server — FAILED"
                printf '%s\n' "$out"
                fail=1
            fi
        fi
    fi
    exit "$fail"
} >"$tmp_mcp_server" 2>&1 &
pids+=($!)
labels+=(mcp-server)
tmps+=("$tmp_mcp_server")

# ── Core-gated tail overlap: fold the phase-2 tail into phase 1's pool ──────
# When TAIL_OVERLAP=1, the three load-sensitive populations join the SAME
# pids/labels/tmps arrays the wait loop below already drains, instead of
# running serially after it. This is exactly the existing backgrounded-stage
# pattern used above (spawn async so `set -e` never fires at spawn time;
# failure is captured by `wait` returning non-zero, same as every other
# phase-1 stage).
if [ "$TAIL_OVERLAP" = "1" ]; then
    { HOOK_TEST_EXCLUDE="$HOOK_DEDUP_EXCLUDE" ./harnesses/claude/hooks/run-tests.sh; } >"$tmp_hooks" 2>&1 &
    pids+=($!)
    labels+=(hooks)
    tmps+=("$tmp_hooks")
    { make --no-print-directory test-hermetic; } >"$tmp_test_hermetic" 2>&1 &
    pids+=($!)
    labels+=(test-hermetic)
    tmps+=("$tmp_test_hermetic")
    { make --no-print-directory rule-render-freshness; } >"$tmp_rule_render_freshness" 2>&1 &
    pids+=($!)
    labels+=(rule-render-freshness)
    tmps+=("$tmp_rule_render_freshness")
fi

fail=0
failed_labels=()
for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
        fail=1
        failed_labels+=("${labels[$i]}")
        printf '===== %s =====\n' "${labels[$i]}"
        cat "${tmps[$i]}"
    fi
done

# ── Phase 2: serial isolation tail (only when NOT overlapped) ──────────────
# Load-sensitive populations run ONE AT A TIME, after phase 1 fully joins.
# Each still runs even if an earlier tail population (or phase 1) failed.
# When TAIL_OVERLAP=1 these already ran above, folded into phase 1's pool —
# this block is skipped entirely on that branch (tmp_hooks/tmp_test_hermetic/
# tmp_rule_render_freshness were already mktemp'd unconditionally above, so
# cleanup at the end of the script is identical on both branches).
if [ "$TAIL_OVERLAP" != "1" ]; then
    if ! { HOOK_TEST_EXCLUDE="$HOOK_DEDUP_EXCLUDE" ./harnesses/claude/hooks/run-tests.sh; } >"$tmp_hooks" 2>&1; then
        fail=1
        failed_labels+=(hooks)
        printf '===== %s =====\n' hooks
        cat "$tmp_hooks"
    fi
    labels+=(hooks)
    tmps+=("$tmp_hooks")

    if ! { make --no-print-directory test-hermetic; } >"$tmp_test_hermetic" 2>&1; then
        fail=1
        failed_labels+=(test-hermetic)
        printf '===== %s =====\n' test-hermetic
        cat "$tmp_test_hermetic"
    fi
    labels+=(test-hermetic)
    tmps+=("$tmp_test_hermetic")

    if ! { make --no-print-directory rule-render-freshness; } >"$tmp_rule_render_freshness" 2>&1; then
        fail=1
        failed_labels+=(rule-render-freshness)
        printf '===== %s =====\n' rule-render-freshness
        cat "$tmp_rule_render_freshness"
    fi
    labels+=(rule-render-freshness)
    tmps+=("$tmp_rule_render_freshness")
fi

# ── Tracked-tree isolation backstop: compare exit snapshot to entry ────────
tmp_tree_after=$(mktemp)
if ! git diff --binary --full-index HEAD -- >"$tmp_tree_after" 2>&1; then
    fail=1
    failed_labels+=(tracked-tree-isolation)
    printf '===== %s =====\n' tracked-tree-isolation
    echo "tracked-tree-isolation: FAILED to capture exit snapshot"
    cat "$tmp_tree_after"
elif ! cmp -s "$tmp_tree_before" "$tmp_tree_after"; then
    fail=1
    failed_labels+=(tracked-tree-isolation)
    printf '===== %s =====\n' tracked-tree-isolation
    echo "tracked-tree-isolation: the suite mutated tracked files. diff of snapshots (before vs after):"
    diff -u "$tmp_tree_before" "$tmp_tree_after" || true
fi
rm -f "$tmp_tree_before" "$tmp_tree_after"

tmp_untracked_after=$(mktemp)
if ! git status --porcelain --untracked-files=all -- >"$tmp_untracked_after" 2>&1; then
    fail=1
    failed_labels+=(tracked-tree-isolation)
    printf '===== %s =====\n' tracked-tree-isolation
    echo "tracked-tree-isolation: FAILED to capture untracked exit snapshot"
    cat "$tmp_untracked_after"
else
    tmp_untracked_new=$(mktemp)
    comm -13 <(sort "$tmp_untracked_before") <(sort "$tmp_untracked_after") >"$tmp_untracked_new" || true
    if [ -s "$tmp_untracked_new" ]; then
        fail=1
        failed_labels+=(tracked-tree-isolation)
        printf '===== %s =====\n' tracked-tree-isolation
        echo "tracked-tree-isolation: the suite leaked new untracked path(s) into the repo:"
        cat "$tmp_untracked_new"
    fi
    rm -f "$tmp_untracked_new"
fi
rm -f "$tmp_untracked_before" "$tmp_untracked_after"

if [ "$fail" -eq 0 ]; then
    echo "ALL CLEAR ✅ make test"
else
    bash_fails=$(cat "$tmp_hooks" "$tmp_scaffold" "$tmp_install" 2>/dev/null | grep -oE 'FAIL: [^ —]+' | sed 's/FAIL: //' | tr '\n' ',' | sed 's/,$//' || true)
    npm_fails=$(cat "$tmp_mcp_server" 2>/dev/null | grep -oE '▶ Test: [^ —]+' | sed 's/▶ Test: //' | tr '\n' ',' | sed 's/,$//' || true)
    all_fails="$bash_fails"
    [ -n "$npm_fails" ] && [ -n "$all_fails" ] && all_fails="$all_fails,$npm_fails" || all_fails="$all_fails$npm_fails"
    joined=$(printf '%s, ' "${failed_labels[@]}")
    joined=${joined%, }
    if [ -n "$all_fails" ]; then
        echo "FAILED ❌ make test — $joined ($all_fails)"
    else
        echo "FAILED ❌ make test — $joined"
    fi
fi
rm -f "$tmp_hooks" "$tmp_scaffold" "$tmp_install" "$tmp_mcp_server" \
    "$tmp_hook_parity" "$tmp_hook_header_parity" "$tmp_harness_parity" "$tmp_test_generator" \
    "$tmp_enforce_registry_parity" "$tmp_enforce_hook_rationale" "$tmp_test_hermetic" \
    "$tmp_prompt_content_parity" "$tmp_rule_render_freshness" \
    "$tmp_usage_rules_index_parity" "$tmp_prompt_size_budget" "$tmp_pitch_scope_parity"
exit "$fail"
