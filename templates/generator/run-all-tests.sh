#!/usr/bin/env bash
# run-all-tests.sh — the `make test` orchestrator, extracted from the
# Makefile `test:` recipe for reviewability/testability.
#
# Runs every PreToolUse/SubagentStop/Stop hook unit-test script in parallel,
# plus every gate check, in ONE pass — not fail-fast. All 11 former prereq
# checks (hook-parity, hook-header-parity, harness-parity, test-generator,
# enforce-registry-parity, enforce-hook-rationale, test-hermetic,
# prompt-content-parity, tools-header-no-dup, rule-render-freshness,
# usage-rules-index-parity, prompt-size-budget, pitch-scope-parity) run as backgrounded `make` stages alongside the
# existing hooks/scaffold/install/npm stages, so a single `make test` surfaces
# every independent failure at once instead of stopping at the first failing
# prereq.
#
# Each *_test.sh is hermetic — own tmp dirs, no shared state — so parallel is
# safe. Job count caps at 8 to avoid thrashing on smaller machines.
#
# Post-deps stages (hook-tests, phoenix scaffold, test_harness/install, npm)
# run concurrently via & + wait to reduce wall time.
set -e
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR"

tmp_prebuild=$(mktemp)
subagents_ext_dir="$SCRIPT_DIR/harnesses/pi/pi-extensions/subagents"
if [ -f "$subagents_ext_dir/package.json" ] && grep -q '"build"[[:space:]]*:' "$subagents_ext_dir/package.json"; then
    (cd "$subagents_ext_dir" && mise exec -- npm run build) >>"$tmp_prebuild" 2>&1 || {
        cat "$tmp_prebuild"
        echo "subagents pre-build failed"
        rm -f "$tmp_prebuild"
        exit 1
    }
fi
enforcement_ext_dir="$SCRIPT_DIR/harnesses/pi/pi-extensions/enforcement"
if [ -f "$enforcement_ext_dir/package.json" ] && grep -q '"build"[[:space:]]*:' "$enforcement_ext_dir/package.json"; then
    (cd "$enforcement_ext_dir" && mise exec -- npm run build) >>"$tmp_prebuild" 2>&1 || {
        cat "$tmp_prebuild"
        echo "enforcement pre-build failed"
        rm -f "$tmp_prebuild"
        exit 1
    }
fi
rm -f "$tmp_prebuild"
tmp_hooks=$(mktemp)
tmp_scaffold=$(mktemp)
tmp_install=$(mktemp)
tmp_npm=$(mktemp)
tmp_subagents=$(mktemp)
tmp_hook_parity=$(mktemp)
tmp_hook_header_parity=$(mktemp)
tmp_harness_parity=$(mktemp)
tmp_test_generator=$(mktemp)
tmp_enforce_registry_parity=$(mktemp)
tmp_enforce_hook_rationale=$(mktemp)
tmp_test_hermetic=$(mktemp)
tmp_prompt_content_parity=$(mktemp)
tmp_tools_header_no_dup=$(mktemp)
tmp_rule_render_freshness=$(mktemp)
tmp_usage_rules_index_parity=$(mktemp)
tmp_prompt_size_budget=$(mktemp)
tmp_pitch_scope_parity=$(mktemp)
pids=()
labels=()
tmps=()
{ ./harnesses/claude/hooks/run-tests.sh; } >"$tmp_hooks" 2>&1 &
pids+=($!)
labels+=(hooks)
tmps+=("$tmp_hooks")
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
{ make --no-print-directory test-hermetic; } >"$tmp_test_hermetic" 2>&1 &
pids+=($!)
labels+=(test-hermetic)
tmps+=("$tmp_test_hermetic")
{ make --no-print-directory prompt-content-parity; } >"$tmp_prompt_content_parity" 2>&1 &
pids+=($!)
labels+=(prompt-content-parity)
tmps+=("$tmp_prompt_content_parity")
{ make --no-print-directory tools-header-no-dup; } >"$tmp_tools_header_no_dup" 2>&1 &
pids+=($!)
labels+=(tools-header-no-dup)
tmps+=("$tmp_tools_header_no_dup")
{ make --no-print-directory rule-render-freshness; } >"$tmp_rule_render_freshness" 2>&1 &
pids+=($!)
labels+=(rule-render-freshness)
tmps+=("$tmp_rule_render_freshness")
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
{
    fail=0
    for ext in enforcement askuserquestion subagents web-utils; do
        ext_dir="$SCRIPT_DIR/harnesses/pi/pi-extensions/$ext"
        if [ -f "$ext_dir/package.json" ] && grep -q '"test"[[:space:]]*:' "$ext_dir/package.json"; then
            if [ "$ext" != "subagents" ] && [ "$ext" != "enforcement" ] && grep -q '"build"[[:space:]]*:' "$ext_dir/package.json"; then
                (cd "$ext_dir" && mise exec -- npm run build) || fail=1
            fi
            if [ -n "$VERBOSE" ]; then
                echo "▶ Test: $ext"
                (cd "$ext_dir" && mise exec -- npm test) || fail=1
            else
                out=$(cd "$ext_dir" && mise exec -- npm test 2>&1)
                rc=$?
                if [ $rc -ne 0 ]; then
                    echo "▶ Test: $ext — FAILED"
                    printf '%s\n' "$out"
                    fail=1
                fi
            fi
        fi
    done
    exit "$fail"
} >"$tmp_npm" 2>&1 &
pids+=($!)
labels+=(npm-ext)
tmps+=("$tmp_npm")
{
    ext_dir="$SCRIPT_DIR/harnesses/pi/pi-extensions/subagents"
    if [ -d "$ext_dir/test/integration" ] && [ -n "$(ls "$ext_dir/test/integration/"*.test.ts 2>/dev/null)" ]; then
        if [ -n "$VERBOSE" ]; then
            echo "▶ Test:integration: subagents"
            (cd "$ext_dir" && mise exec -- npm run test:integration) || exit 1
        else
            out=$(cd "$ext_dir" && mise exec -- npm run test:integration 2>&1)
            rc=$?
            if [ $rc -ne 0 ]; then
                echo "▶ Test:integration: subagents — FAILED"
                printf '%s\n' "$out"
                exit 1
            fi
        fi
    fi
} >"$tmp_subagents" 2>&1 &
pids+=($!)
labels+=(subagents-integration)
tmps+=("$tmp_subagents")
tmp_mcp_server=$(mktemp)
{
    mcp_dir="$SCRIPT_DIR/harnesses/claude/mcp-server"
    if [ -f "$mcp_dir/package.json" ] && grep -q '"test"[[:space:]]*:' "$mcp_dir/package.json"; then
        if [ -n "$VERBOSE" ]; then
            echo "▶ Test: mcp-server"
            (cd "$mcp_dir" && mise exec -- npm test) || exit 1
        else
            out=$(cd "$mcp_dir" && mise exec -- npm test 2>&1)
            rc=$?
            if [ $rc -ne 0 ]; then
                echo "▶ Test: mcp-server — FAILED"
                printf '%s\n' "$out"
                exit 1
            fi
        fi
    fi
} >"$tmp_mcp_server" 2>&1 &
pids+=($!)
labels+=(mcp-server)
tmps+=("$tmp_mcp_server")
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
if [ "$fail" -eq 0 ]; then
    echo "ALL CLEAR ✅ make test"
else
    bash_fails=$(cat "$tmp_hooks" "$tmp_scaffold" "$tmp_install" 2>/dev/null | grep -oE 'FAIL: [^ —]+' | sed 's/FAIL: //' | tr '\n' ',' | sed 's/,$//' || true)
    npm_fails=$(cat "$tmp_npm" "$tmp_subagents" "$tmp_mcp_server" 2>/dev/null | grep -oE '▶ Test: [^ —]+' | sed 's/▶ Test: //' | tr '\n' ',' | sed 's/,$//' || true)
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
rm -f "$tmp_hooks" "$tmp_scaffold" "$tmp_install" "$tmp_npm" "$tmp_subagents" "$tmp_mcp_server" \
    "$tmp_hook_parity" "$tmp_hook_header_parity" "$tmp_harness_parity" "$tmp_test_generator" \
    "$tmp_enforce_registry_parity" "$tmp_enforce_hook_rationale" "$tmp_test_hermetic" \
    "$tmp_prompt_content_parity" "$tmp_tools_header_no_dup" "$tmp_rule_render_freshness" \
    "$tmp_usage_rules_index_parity" "$tmp_prompt_size_budget" "$tmp_pitch_scope_parity"
exit "$fail"
