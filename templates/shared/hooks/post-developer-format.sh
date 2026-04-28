#!/bin/bash
# post-developer-format.sh — SubagentStop hook for developer subagents.
#
# Purpose: when phoenix-developer / data-layer-developer / static-site-developer
# reports done, auto-format their diff so verification-engineer never sees a
# prettier-only or mix-format-only failure. Also surface any LLM-test signal.
#
# Behaviour:
#   - phoenix-developer / data-layer-developer:
#       * mix format on changed .ex/.exs/.heex files
#       * npx prettier --write on changed prettier-relevant files
#   - static-site-developer:
#       * npx prettier --write on changed files
#   - All developers: detect LLM-affecting paths in the diff and write a
#     pending-flag file the orchestrator can check.
#
# This is a fix-up hook, not a gate: always exits 0 unless the orchestrator
# wants the LLM signal injected via a `decision: block` reason.
#
# Field-name notes (verified experimentally on Claude Code 2.1.119):
#   - SubagentStop stdin contains: agent_type (= the configured subagent name),
#     agent_id, session_id, transcript_path, agent_transcript_path,
#     last_assistant_message, stop_hook_active, cwd.
#   - cwd in stdin reflects the orchestrator's project root, so mix format
#     and prettier can be invoked from there (we cd into it for safety).
#   - Hook stdout/stderr is NOT propagated to the orchestrator on exit 0
#     (verified). Only `{"decision":"block","reason":"..."}` reaches the
#     orchestrator — and that re-runs the subagent, which we DON'T want here.
#     So we surface the LLM signal via a sidecar file instead.

set -u

input=$(cat)

agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')
session_id=$(printf '%s' "$input" | jq -r '.session_id // ""')
project_dir=$(printf '%s' "$input" | jq -r '.cwd // ""')
stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')

# Loop guard — if a previous SubagentStop hook already fired for this stop,
# bail to avoid recursion if anyone ever wires a `decision: block` here.
if [ "$stop_hook_active" = "true" ]; then
    exit 0
fi

# Fall back to env var / pwd if cwd field missing.
if [ -z "$project_dir" ]; then
    project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

log() {
    if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ]; then
        printf '%s post-developer-format agent=%s session=%s %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$agent_type" "$session_id" "$*" \
            >>/tmp/post-developer-format-debug.log 2>/dev/null || true
    fi
}

log "fired cwd=$project_dir"

case "$agent_type" in
phoenix-developer | data-layer-developer | static-site-developer) ;;
*)
    log "skip (not a developer agent_type)"
    exit 0
    ;;
esac

cd "$project_dir" 2>/dev/null || {
    log "could not cd to project_dir, exiting"
    exit 0
}

# Bail if not a git repo (no diff to format).
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log "not a git repo, skipping"
    exit 0
fi

# Collect changed paths: staged + unstaged + untracked, NUL-separated for safety.
changed=$({
    git diff --name-only --diff-filter=ACMR -z HEAD 2>/dev/null
    git ls-files --others --exclude-standard -z 2>/dev/null
} | tr '\0' '\n' | awk 'NF' | sort -u)

if [ -z "$changed" ]; then
    log "no changed files"
    exit 0
fi

log "changed files: $(echo "$changed" | tr '\n' ' ')"

# ── Phoenix / data-layer: mix format on Elixir files ─────────────────────────
if [ "$agent_type" = "phoenix-developer" ] || [ "$agent_type" = "data-layer-developer" ]; then
    ex_files=$(printf '%s\n' "$changed" | grep -E '\.(ex|exs|heex)$' || true)
    if [ -n "$ex_files" ]; then
        # Pass paths as args; mix format handles missing files gracefully.
        # shellcheck disable=SC2086
        printf '%s\n' "$ex_files" | xargs mix format >/dev/null 2>&1 || log "mix format had errors (non-fatal)"
        log "mix format ran on $(echo "$ex_files" | wc -l | tr -d ' ') file(s)"
    fi
fi

# ── All developers: prettier on prettier-relevant files ──────────────────────
prettier_files=$(printf '%s\n' "$changed" | grep -E '\.(js|ts|jsx|tsx|css|scss|json|md|yml|yaml|html)$' || true)
if [ -n "$prettier_files" ]; then
    # Filter out files prettier doesn't know about by piping through xargs
    # with --no-run-if-empty equivalent.
    if command -v npx >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        printf '%s\n' "$prettier_files" | xargs npx --no-install prettier --write --log-level=warn >/dev/null 2>&1 ||
            log "prettier had errors (non-fatal)"
        log "prettier ran on $(echo "$prettier_files" | wc -l | tr -d ' ') file(s)"
    fi
fi

# ── LLM-test signal detection ────────────────────────────────────────────────
llm_pattern='context/llm\.md|.*\.md\.j2|codegen/rules/|codegen/recipes/|context/apps/CLAUDE-.*\.md|PLATFORM_INFO\.md'
if printf '%s\n' "$changed" | grep -qE "$llm_pattern"; then
    flag_dir="${project_dir}/codegen/llm-pending"
    mkdir -p "$flag_dir" 2>/dev/null || true
    flag_file="$flag_dir/${session_id}.flag"
    {
        printf 'agent_type=%s\n' "$agent_type"
        printf 'changed_llm_files:\n'
        printf '%s\n' "$changed" | grep -E "$llm_pattern" | sed 's/^/  /'
    } >"$flag_file" 2>/dev/null || true
    log "LLM-test signal raised: $flag_file"
fi

exit 0
