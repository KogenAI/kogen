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

# Collect changed ABSOLUTE paths from project_dir + each known sibling repo.
# Developer subagents may edit files in OCG sibling repos (codegen, context),
# whose changes don't appear in the combobulate `git diff`. Run each repo's
# diff separately and concatenate absolute paths.
collect_changed_abs() {
    local repo="$1"
    [ -d "$repo/.git" ] || return 0
    (
        cd "$repo" 2>/dev/null || exit 0
        {
            git diff --name-only --diff-filter=ACMR -z HEAD 2>/dev/null
            git ls-files --others --exclude-standard -z 2>/dev/null
        } | tr '\0' '\n' | awk -v root="$repo" 'NF { print root"/"$0 }'
    )
}

candidate_repos=("$project_dir")
# Sibling OCG repos — only added if they exist as git repos.
for sibling in /Users/almirsarajcic/Areas/Optimum/codegen /Users/almirsarajcic/Areas/Optimum/context; do
    if [ -d "$sibling/.git" ] && [ "$sibling" != "$project_dir" ]; then
        candidate_repos+=("$sibling")
    fi
done

changed_abs=""
for repo in "${candidate_repos[@]}"; do
    repo_changes=$(collect_changed_abs "$repo")
    if [ -n "$repo_changes" ]; then
        changed_abs="${changed_abs}${repo_changes}
"
    fi
done

# Trim trailing blank lines and dedup.
changed_abs=$(printf '%s' "$changed_abs" | awk 'NF' | sort -u)

if [ -z "$changed_abs" ]; then
    log "no changed files"
    exit 0
fi

log "changed files: $(echo "$changed_abs" | tr '\n' ' ')"

# Bucket changed files by their containing git repo root, so formatters run
# from each repo's root with paths relative to that root.
declare -A files_by_repo
while IFS= read -r abs_path; do
    [ -z "$abs_path" ] && continue
    repo_root=$(cd "$(dirname "$abs_path")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || {
        log "skipping $abs_path (not in a git repo)"
        continue
    }
    files_by_repo["$repo_root"]+="$abs_path"$'\n'
done <<<"$changed_abs"

# Combined list across all repos (relative paths) for LLM-signal detection.
all_relative=""

for repo_root in "${!files_by_repo[@]}"; do
    bucket="${files_by_repo[$repo_root]}"
    # Convert absolute paths to repo-relative paths.
    rel_files=$(printf '%s' "$bucket" | awk 'NF' | sed "s|^${repo_root}/||")
    [ -z "$rel_files" ] && continue
    all_relative="${all_relative}${rel_files}
"

    # ── mix format on Elixir files (phoenix/data-layer only) ─────────────────
    if [ "$agent_type" = "phoenix-developer" ] || [ "$agent_type" = "data-layer-developer" ]; then
        ex_files=$(printf '%s\n' "$rel_files" | grep -E '\.(ex|exs|heex)$' || true)
        if [ -n "$ex_files" ] && [ -f "$repo_root/mix.exs" ]; then
            (
                cd "$repo_root" 2>/dev/null || exit 0
                # shellcheck disable=SC2086
                printf '%s\n' "$ex_files" | xargs mix format >/dev/null 2>&1
            ) || log "mix format had errors in $repo_root (non-fatal)"
            log "mix format ran in $repo_root on $(echo "$ex_files" | wc -l | tr -d ' ') file(s)"
        fi
    fi

    # ── prettier on prettier-relevant files (all developers) ─────────────────
    prettier_files=$(printf '%s\n' "$rel_files" | grep -E '\.(js|ts|jsx|tsx|css|scss|json|md|yml|yaml|html)$' || true)
    if [ -n "$prettier_files" ] && command -v npx >/dev/null 2>&1; then
        (
            cd "$repo_root" 2>/dev/null || exit 0
            # shellcheck disable=SC2086
            printf '%s\n' "$prettier_files" | xargs npx --no-install prettier --write --log-level=warn >/dev/null 2>&1
        ) || log "prettier had errors in $repo_root (non-fatal)"
        log "prettier ran in $repo_root on $(echo "$prettier_files" | wc -l | tr -d ' ') file(s)"
    fi
done

# ── LLM-test signal detection (across all repos) ─────────────────────────────
all_relative=$(printf '%s' "$all_relative" | awk 'NF')
llm_pattern='context/llm\.md|.*\.md\.j2|codegen/rules/|codegen/recipes/|context/apps/CLAUDE-.*\.md|PLATFORM_INFO\.md'
if printf '%s\n' "$all_relative" | grep -qE "$llm_pattern"; then
    flag_dir="${project_dir}/codegen/llm-pending"
    mkdir -p "$flag_dir" 2>/dev/null || true
    flag_file="$flag_dir/${session_id}.flag"
    {
        printf 'agent_type=%s\n' "$agent_type"
        printf 'changed_llm_files:\n'
        printf '%s\n' "$all_relative" | grep -E "$llm_pattern" | sed 's/^/  /'
    } >"$flag_file" 2>/dev/null || true
    log "LLM-test signal raised: $flag_file"
fi

exit 0
