#!/bin/bash
# post-developer-format.sh — SubagentStop hook for developer subagents.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: developer-phoenix-backend|developer-phoenix-frontend|developer-html|developer-hugo|developer-vite
# surface: user_global
# signal: AGENT_TYPE
# role: developer-phoenix-backend|developer-phoenix-frontend|developer-html|developer-hugo|developer-vite
# harnesses: all
#
# Purpose: when developer-phoenix-backend / developer-phoenix-frontend / developer-html | developer-hugo | developer-vite
# reports done, auto-format their diff so the dev-gate.sh hook never sees a
# prettier-only or mix-format-only failure. Also surface any LLM-test signal.
#
# Scans the full branch diff (origin/main..HEAD) — not just the working-tree
# changes — so files committed in earlier steps of a multi-step session are
# included and formatted.
#
# Behaviour:
#   - developer-phoenix-backend / developer-phoenix-frontend:
#       * mix format on changed .ex/.exs/.heex files
#       * npx prettier --write on changed prettier-relevant files
#   - developer-html | developer-hugo | developer-vite:
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

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

agent_type="$AGENT_TYPE"
session_id="$SESSION_ID"
project_dir="$CWD"

# Loop guard — if a previous SubagentStop hook already fired for this stop,
# bail to avoid recursion if anyone ever wires a `decision: block` here.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# Fall back to env var / pwd if cwd field missing.
if [ -z "$project_dir" ]; then
    project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

log() {
    debug_log post-developer-format "agent=$agent_type session=$session_id $*"
}

log "fired cwd=$project_dir"

case "$agent_type" in
developer-phoenix-backend | developer-phoenix-frontend | developer-html | developer-hugo | developer-vite) ;;
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

# ── Collect changed ABSOLUTE paths ───────────────────────────────────────────
#
# Strategy (in priority order):
#
# 1. Ledger path — if track-subagent-edits.sh is installed and the current
#    subagent has written a ledger (~/.claude/post-format/<session>_<agent>.txt),
#    use ONLY those files. Scoped per subagent → no parallel-dev collisions.
#
# 2. Git diff fallback — if no ledger exists (legacy hook not installed, or
#    orchestrator-level stop), fall back to the original git diff approach.
#    Bug-for-bug compatible: formats per-repo branch diff + untracked files.

agent_id="$AGENT_ID"
ledger_file=""
if [ -n "$SESSION_ID" ] && [ -n "$agent_id" ]; then
    ledger_file="$HOME/.claude/post-format/${SESSION_ID}_${agent_id}.txt"
fi

collect_changed_abs_git() {
    local repo="$1"
    [ -d "$repo/.git" ] || return 0
    (
        cd "$repo" 2>/dev/null || exit 0
        # Use full branch diff (origin/main..HEAD) so files committed in earlier
        # steps of a multi-step session are included — not just working-tree changes.
        # Fall back to HEAD diff if origin/main is unavailable (e.g. no remote).
        branch_base=$(git merge-base origin/main HEAD 2>/dev/null || echo "HEAD")
        {
            git diff --name-only --diff-filter=ACMR -z "${branch_base}" HEAD 2>/dev/null
            git diff --name-only --diff-filter=ACMR -z HEAD 2>/dev/null
            git ls-files --others --exclude-standard -z 2>/dev/null
        } | tr '\0' '\n' | awk -v root="$repo" 'NF { print root"/"$0 }'
    )
}

changed_abs=""

if [ -n "$ledger_file" ] && [ -f "$ledger_file" ] && [ -s "$ledger_file" ]; then
    # Ledger path: use per-subagent file list, already absolute paths.
    log "using ledger=$ledger_file"
    changed_abs=$(sort -u "$ledger_file")
else
    # Git diff fallback (legacy): scan project_dir + known sibling repos.
    log "ledger not found or empty — falling back to git diff"
    candidate_repos=("$project_dir")
    # Sibling OCG repos — only added if they exist as git repos.
    for sibling in /Users/almirsarajcic/Areas/Optimum/codegen /Users/almirsarajcic/Areas/Optimum/context; do
        if [ -d "$sibling/.git" ] && [ "$sibling" != "$project_dir" ]; then
            candidate_repos+=("$sibling")
        fi
    done

    for repo in "${candidate_repos[@]}"; do
        repo_changes=$(collect_changed_abs_git "$repo")
        if [ -n "$repo_changes" ]; then
            changed_abs="${changed_abs}${repo_changes}
"
        fi
    done
fi

# Trim trailing blank lines and dedup.
changed_abs=$(printf '%s' "$changed_abs" | awk 'NF' | sort -u)

if [ -z "$changed_abs" ]; then
    log "no changed files"
    exit 0
fi

log "changed files: $(echo "$changed_abs" | tr '\n' ' ')"

# ── make format shortcut ──────────────────────────────────────────────────────
# If the project defines a `make format` target, delegate entirely to it.
# This covers formatters the hook doesn't know about (shfmt, custom tools).
if grep -q '^format:' "$project_dir/Makefile" 2>/dev/null; then
    log "make format target found — delegating to make format"
    (cd "$project_dir" && make format >/dev/null 2>&1) || log "make format had errors (non-fatal)"
    # Still run LLM-signal detection below, but skip per-file formatter logic.
    _ran_make_format=1
else
    _ran_make_format=0
fi

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

if [ "$_ran_make_format" -eq 0 ]; then
    for repo_root in "${!files_by_repo[@]}"; do
        bucket="${files_by_repo[$repo_root]}"
        # Convert absolute paths to repo-relative paths.
        rel_files=$(printf '%s' "$bucket" | awk 'NF' | sed "s|^${repo_root}/||")
        [ -z "$rel_files" ] && continue
        all_relative="${all_relative}${rel_files}
"

        # ── mix format on Elixir files (phoenix/data-layer only) ─────────────────
        if [ "$agent_type" = "developer-phoenix-backend" ] || [ "$agent_type" = "developer-phoenix-frontend" ]; then
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
else
    # make format ran — still populate all_relative for LLM-signal detection.
    for repo_root in "${!files_by_repo[@]}"; do
        bucket="${files_by_repo[$repo_root]}"
        rel_files=$(printf '%s' "$bucket" | awk 'NF' | sed "s|^${repo_root}/||")
        [ -z "$rel_files" ] && continue
        all_relative="${all_relative}${rel_files}
"
    done
fi

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

# ── Ledger cleanup ────────────────────────────────────────────────────────────
# Delete the per-subagent ledger now that formatting is complete.
# Stale ledgers (older than 7 days) are also GC'd here as a safety net.
if [ -n "$ledger_file" ] && [ -f "$ledger_file" ]; then
    rm -f "$ledger_file"
    log "deleted ledger=$ledger_file"
fi
# GC stale ledgers older than 7 days.
ledger_dir="$HOME/.claude/post-format"
if [ -d "$ledger_dir" ]; then
    find "$ledger_dir" -maxdepth 1 -name "*.txt" -mtime +7 -delete 2>/dev/null || true
fi

exit 0
