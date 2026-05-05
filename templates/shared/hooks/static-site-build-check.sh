#!/usr/bin/env bash
# static-site-build-check.sh — SubagentStop hook for static-site-developer.
#
# Purpose: replace the LLM static-site-verifier subagent with a deterministic
# build check. Runs four invariants from the static site's working tree and
# emits a Stop-event `block` envelope on failure so the developer subagent
# is re-spawned with the failure reason. Appends a synthetic
# `## static-site-verifier Section` to the active step log on success so
# the orchestrator's chain detector still sees the role marker.
#
# Checks (deterministic order, first failure short-circuits):
#   1. `mise exec -- npm run build` — skip if no package.json (Hugo case).
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
parse_input

agent_type="$AGENT_TYPE"
session_id="$SESSION_ID"
project_dir="$CWD"

# Loop guard — bail if a previous SubagentStop already fired for this stop.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log static-site-build-check "skip: stop_hook_active session=$session_id"
    exit 0
fi

# Only fire for static-site-developer.
if [ "$agent_type" != "static-site-developer" ]; then
    debug_log static-site-build-check "skip: agent_type=$agent_type"
    exit 0
fi

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
check_npm_build() {
    [ -f package.json ] || return 0

    local out
    if ! out=$(mise exec -- npm run build 2>&1); then
        local tail_out
        tail_out=$(printf '%s' "$out" | tail -n 30)
        fail "npm run build failed: $tail_out"
    fi
}

# ── Check 2: package.json invariants ────────────────────────────────────────
check_package_json_invariants() {
    [ -f package.json ] || return 0

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
    if grep -rE '^@tailwind ' --include='*.css' . >/dev/null 2>&1; then
        fail "Tailwind v3 @tailwind directive found — use @import \"tailwindcss\"; instead"
    fi
}

check_npm_build
check_package_json_invariants
check_tailwind_v4_config
check_tailwind_directives

# ── Success: append synthetic SSV section to the active step log ────────────
logging_dir="$project_dir/codegen/logging"
if [ -d "$logging_dir" ]; then
    log_file=$(find "$logging_dir" -maxdepth 1 -type f -name '*.md' -mmin -60 2>/dev/null |
        xargs -I{} stat -f '%m %N' {} 2>/dev/null |
        sort -rn |
        head -n 1 |
        awk '{$1=""; sub(/^ /, ""); print}')

    if [ -n "$log_file" ] && [ -w "$log_file" ]; then
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        {
            printf '\n## static-site-verifier Section\n\n'
            printf '**Rules loaded**: deterministic hook (static-site-build-check.sh) — no rules loaded\n\n'
            printf '**Commands executed**:\n\n'
            printf '| Time (HH:MM:SS UTC) | Command | Exit | Notes |\n'
            printf '| ------------------- | ------- | ---- | ----- |\n'
            printf '| %s | mise exec -- npm run build | 0 | (skipped if no package.json) |\n' "$ts"
            printf '| %s | jq .scripts.build/.scripts.serve | 0 | package.json invariants |\n' "$ts"
            printf '| %s | test -f tailwind.config.js / postcss.config.js | 1 | Tailwind v4 config absence |\n' "$ts"
            printf '| %s | grep -rE @tailwind --include=*.css . | 1 | Tailwind v4 directive check |\n' "$ts"
            printf '\n**Result**: ALL CLEAR ✅\n'
        } >>"$log_file"
        debug_log static-site-build-check "appended SSV section to $log_file"
    else
        debug_log static-site-build-check "no recent step log under $logging_dir"
    fi
fi

exit 0
