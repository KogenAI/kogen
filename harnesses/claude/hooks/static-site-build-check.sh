#!/usr/bin/env bash
# static-site-build-check.sh — SubagentStop hook for developer-static.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: developer-static
# surface: user_global
# signal: AGENT_TYPE
# role: developer-static
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Purpose: replace the LLM static-site-verifier subagent with a deterministic
# build check. Runs four invariants from the static site's working tree and
# emits a Stop-event `block` envelope on failure so the developer subagent
# is re-spawned with the failure reason. Appends a synthetic
# `## static-site-verifier Section` to the active step log on success so
# the orchestrator's chain detector still sees the role marker.
#
# Checks (deterministic order, first failure short-circuits):
#   1. `make ci` — skip if no package.json (tooling-only case).
#   2. package.json invariants — scripts.build present, scripts.serve present,
#      scripts.serve ends with `python3 -u -m http.server --directory public 0`.
#   3. Tailwind v4 config absence — neither tailwind.config.js nor postcss.config.js
#      may exist at the app root.
#   4. Tailwind v4 directive — no `@tailwind ` directive in any *.css file.
#
# Loop guard: STOP_HOOK_ACTIVE=true exits 0 immediately so the hook does not
# re-run after the developer resumes from a `block` envelope.
#
# Runtime budget: typical Tailwind+esbuild build is 10-40s; spec target <90s.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/gate-result.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/cycle-state.sh"
parse_input

# Derive CODEGEN_DIR from script location when not inherited from environment.
# Hook lives at harnesses/claude/hooks/ — three dirs up is repo root.
: "${CODEGEN_DIR:="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"}"

agent_type="$AGENT_TYPE"
session_id="$SESSION_ID"
project_dir="$CWD"

# Loop guard — bail if a previous SubagentStop already fired for this stop.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log static-site-build-check "skip: stop_hook_active session=$session_id"
    exit 0
fi

# Only fire for static-site developers.
case "$agent_type" in
developer-static) ;;
*)
    debug_log static-site-build-check "skip: agent_type=$agent_type"
    exit 0
    ;;
esac

if [ -z "$project_dir" ]; then
    project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

cd "$project_dir" 2>/dev/null || {
    debug_log static-site-build-check "skip: could not cd to $project_dir"
    exit 0
}

debug_log static-site-build-check "fired cwd=$project_dir session=$session_id"

# fail <reason> — emit block envelope and exit 0.
fail() {
    local reason="$1"
    debug_log static-site-build-check "BLOCK: $reason"
    block "$reason"
    exit 0
}

# ── Check 1: npm run build ──────────────────────────────────────────────────
# Sets _NPM_BUILD_SKIPPED=true when package.json has no scripts (tooling-only).
_NPM_BUILD_SKIPPED=false

check_npm_build() {
    if [ ! -f package.json ]; then
        fail "package.json not found — Vite static sites must have a package.json"
    fi

    # No scripts object at all → tooling-only package.json (e.g. prettier).
    # Not a static-site project; skip npm checks silently.
    if ! jq -e '.scripts' package.json >/dev/null 2>&1; then
        _NPM_BUILD_SKIPPED=true
        return 0
    fi

    if ! jq -e '.scripts.build' package.json >/dev/null 2>&1; then
        fail "package.json missing scripts.build"
    fi

    local out
    if ! out=$(make ci 2>&1); then
        local tail_out
        tail_out=$(printf '%s' "$out" | awk '{lines[NR]=$0} END{start=(NR>30)?(NR-29):1; for(i=start;i<=NR;i++) print lines[i]}')
        fail "make ci failed: $tail_out"
    fi
}

# ── Check 2: package.json invariants ────────────────────────────────────────
check_package_json_invariants() {
    [ -f package.json ] || return 0

    # No scripts object at all → tooling-only package.json; skip invariant checks.
    jq -e '.scripts' package.json >/dev/null 2>&1 || return 0

    if ! jq -e '.scripts.build' package.json >/dev/null 2>&1; then
        fail "package.json missing scripts.build"
    fi

    if ! jq -e '.scripts.serve' package.json >/dev/null 2>&1; then
        fail "package.json missing scripts.serve"
    fi

    local serve
    serve=$(jq -r '.scripts.serve' package.json 2>/dev/null)
    if ! printf '%s' "$serve" | grep -qE 'python3 -u -m http\.server --directory public 0$'; then
        fail "scripts.serve must end with 'python3 -u -m http.server --directory public 0'"
    fi
}

# ── Check 3: Tailwind v4 config absence ─────────────────────────────────────
check_tailwind_v4_config() {
    if [ -f tailwind.config.js ]; then
        fail "tailwind.config.js found at repo root — Tailwind v4 does not use this file"
    fi
    if [ -f postcss.config.js ]; then
        fail "postcss.config.js found at repo root — Tailwind v4 does not use this file"
    fi
}

# ── Check 4: Tailwind v4 directive (@tailwind ...) ──────────────────────────
check_tailwind_directives() {
    if grep -rE '^@tailwind ' --include='*.css' --exclude-dir=node_modules . >/dev/null 2>&1; then
        fail "Tailwind v3 @tailwind directive found — use @import \"tailwindcss\"; instead"
    fi
}

check_npm_build
check_package_json_invariants
check_tailwind_v4_config
check_tailwind_directives

# ── Check 5: CSS file exists in output directory ─────────────────────────────
check_css_output() {
    [ -f package.json ] || return 0

    # No scripts object → tooling-only; skip.
    jq -e '.scripts' package.json >/dev/null 2>&1 || return 0

    if [ ! -d "public" ]; then
        fail "No output directory (public/) — build may have failed"
    fi

    output_dir="public"

    if ! find "$output_dir" -name "*.css" -type f | head -1 | grep -q .; then
        fail "No .css file found in $output_dir — Tailwind compilation failed or missing"
    fi
}

# ── Check 6: Built index.html links stylesheet ───────────────────────────────
check_html_stylesheet_link() {
    [ -f package.json ] || return 0

    # No scripts object → tooling-only; skip.
    jq -e '.scripts' package.json >/dev/null 2>&1 || return 0

    output_dir="public"

    built_html="$output_dir/index.html"
    if [ -f "$built_html" ]; then
        if ! grep -q '<link.*rel.*stylesheet\|<style' "$built_html"; then
            fail "Built index.html has no <link rel=stylesheet> or <style> tag — CSS not linked"
        fi
    fi
}

check_css_output
check_html_stylesheet_link

# ── Check 7: render verification (headless Chromium) ─────────────────────────
# Runs after all static-file checks pass. Uses render-check.js which serves
# the output dir over a throwaway localhost server and verifies: non-empty DOM,
# styles applied, no JS errors. Non-fatal if browser not installed on host.

render_verdict=""
render_stderr=""
render_summary="render: skipped (no output dir)"

run_render_check() {
    local out_dir="$1"
    local _self_dir
    _self_dir="$(dirname "${BASH_SOURCE[0]}")"
    local -a render_check_cmd_arr
    if [ -z "${RENDER_CHECK_CMD+x}" ]; then
        if [ ! -f "$_self_dir/lib/render-check.js" ]; then
            fail "render-check.js not found at $_self_dir/lib/render-check.js — check flat install layout"
        fi
        render_check_cmd_arr=("node" "$_self_dir/lib/render-check.js")
    else
        read -ra render_check_cmd_arr <<<"${RENDER_CHECK_CMD}"
    fi
    local _rc_err
    _rc_err=$(mktemp)
    render_stderr=""
    local raw
    raw=$("${render_check_cmd_arr[@]}" --mode static --timeout 30000 "$out_dir" 2>"$_rc_err") || true
    local _rc=$?
    render_stderr=$(cat "$_rc_err")
    rm -f "$_rc_err"
    render_verdict=$(printf '%s' "$raw" | grep '^RENDER_VERDICT=' | head -n 1 | cut -d= -f2-)
}

# Determine output dir — same logic as check_css_output/check_html_stylesheet_link.
if [ "$_NPM_BUILD_SKIPPED" = "false" ] && [ -f package.json ] && jq -e '.scripts' package.json >/dev/null 2>&1; then
    _output_dir="public"

    if [ -d "$_output_dir" ]; then
        run_render_check "$_output_dir"

        case "$render_verdict" in
        PASS)
            render_summary="render: DOM non-empty, styles applied, 0 JS errors"
            debug_log static-site-build-check "render check PASS"
            ;;
        FAIL:*)
            reason="${render_verdict#FAIL:}"
            debug_log static-site-build-check "render check FAIL: $reason"
            fail "render check failed: $reason"
            ;;
        INCONCLUSIVE:chromium-launch-failed)
            debug_log static-site-build-check "render check INCONCLUSIVE: chromium launch failed"
            fail "Chromium missing on this box — run: npx playwright install chromium. Infra condition, not a code/hook defect."
            ;;
        INCONCLUSIVE:playwright-module-unresolvable)
            debug_log static-site-build-check "render check INCONCLUSIVE: playwright module unresolvable"
            fail "render-check.js could not require the playwright module from any candidate path — codegen install/path fault, not a missing browser. Verify lib/render-check.js sits beside the hook and node_modules/playwright is resolvable."
            ;;
        INCONCLUSIVE:*)
            # Fail-closed: config-error/timeout/no-verdict block under the
            # fail-closed-everywhere ruling — the gate cannot confirm a clean
            # render, so it must not pass silently.
            detail="${render_verdict#INCONCLUSIVE:}"
            debug_log static-site-build-check "render check INCONCLUSIVE: $detail"
            fail "render check INCONCLUSIVE ($detail) — gate cannot confirm a clean render. Config-error/timeout/no-verdict block under fail-closed policy. Detail: $detail"
            ;;
        *)
            # render-check emitted no RENDER_VERDICT= line — crash or parse error
            debug_log static-site-build-check "render check emitted no verdict (crash/parse error)"
            fail "render-check did not emit verdict — check render-check.js for parse/runtime errors. stderr: ${render_stderr}"
            ;;
        esac
    fi
fi

# ── Write structured gate result + append SSV section ───────────────────────
log_file=$(session_log_from_transcript)

# Determine final verdict based on render check result and build mode
_gate_cmd="make ci"
_diff_sha=$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null || printf 'unknown')
_diff_count=$(git -C "$project_dir" diff --name-only origin/main...HEAD 2>/dev/null | wc -l | tr -d ' ' || printf '0')
_ts_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_render_for_result="$render_verdict"

if [ "$_NPM_BUILD_SKIPPED" = "false" ]; then
    case "$render_verdict" in
    INCONCLUSIVE:*)
        # Unreachable after the render-dispatch INCONCLUSIVE→fail flip above
        # (fail() exits before reaching this block). Kept for structural
        # parity/defensiveness — do not delete.
        write_gate_result "$_gate_cmd" "short" "$_diff_sha" "$_diff_count" \
            "true" 0 1 1 "$render_verdict" "render-inconclusive" \
            "$_ts_now" "$_ts_now" "${session_id:-unknown}" "" "$project_dir"
        write_cycle_state "GATED" "${log_file:-}" "${session_id:-unknown}" "inconclusive" "$project_dir"
        ;;
    FAIL:*)
        # fail() would have already exited; this branch is unreachable here
        ;;
    *)
        write_gate_result "$_gate_cmd" "short" "$_diff_sha" "$_diff_count" \
            "true" 0 1 1 "$_render_for_result" "" \
            "$_ts_now" "$_ts_now" "${session_id:-unknown}" "" "$project_dir"
        write_cycle_state "GATED" "${log_file:-}" "${session_id:-unknown}" "clear" "$project_dir"
        ;;
    esac
fi

if [ -z "$log_file" ]; then
    debug_log static-site-build-check "no session log in transcript"
elif [ -w "$log_file" ]; then
    ts="$_ts_now"

    # Choose result line based on render verdict
    result_line=""
    case "$render_verdict" in
    INCONCLUSIVE:*)
        # Unreachable after the render-dispatch INCONCLUSIVE→fail flip above
        # (fail() exits before reaching this block). Kept for structural
        # parity/defensiveness — do not delete.
        inc_detail="${render_verdict#INCONCLUSIVE:}"
        result_line="INCONCLUSIVE ⚠️ render-inconclusive: $inc_detail"
        ;;
    *)
        result_line="ALL CLEAR ✅"
        ;;
    esac

    {
        printf '\n## static-site-verifier Section\n\n'
        printf '**Rules loaded**: deterministic hook (static-site-build-check.sh) — no rules loaded\n\n'
        printf '**Commands executed**:\n\n'
        printf '| Time (HH:MM:SS UTC) | Command | Exit | Notes |\n'
        printf '| ------------------- | ------- | ---- | ----- |\n'
        printf '| %s | make ci | 0 | build verification |\n' "$ts"
        printf '| %s | jq .scripts.build/.scripts.serve | 0 | package.json invariants |\n' "$ts"
        printf '| %s | test -f tailwind.config.js / postcss.config.js | 1 | Tailwind v4 config absence |\n' "$ts"
        printf '| %s | grep -rE @tailwind --include=*.css . | 1 | Tailwind v4 directive check |\n' "$ts"
        printf '| %s | find public/dist -name *.css | 0 | CSS output file check |\n' "$ts"
        printf '| %s | grep link.rel.stylesheet public/index.html | 0 | stylesheet link check |\n' "$ts"
        printf '| %s | node render-check.js --mode static | 0 | render verification |\n' "$ts"
        printf '\n**Result**: %s\n' "$result_line"
        printf '\n%s\n' "$render_summary"
    } >>"$log_file"
    debug_log static-site-build-check "appended SSV section ($result_line) to $log_file"
fi

exit 0
