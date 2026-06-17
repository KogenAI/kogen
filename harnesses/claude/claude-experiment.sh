#!/usr/bin/env bash
# Experiment mode launcher — single-agent, source-writable, long-running investigation.
# Runs in a native claude --worktree exp-<slug>; narrates findings to a draft pitch.
# Distinct from shape (pitch-only write surface) and debug (read-only investigation).
set -euo pipefail
export CLAUDE_ROLE=experiment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${OCG_CODEGEN_DIR:-}" ]]; then
    CODEGEN_DIR="$OCG_CODEGEN_DIR"
elif [[ -L "$SCRIPT_DIR/harnesses" || -d "$SCRIPT_DIR/harnesses" ]]; then
    CODEGEN_DIR="$(cd -P "$SCRIPT_DIR/harnesses" && cd .. && pwd)"
else
    CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi
export CODEGEN_DIR

# Normalise launch cwd to the nearest legal pitch root so the resolver, the
# CLAUDE_PITCH_PATH export, and the session cwd inherited by claude all key off
# a dir whose ./codegen/pitches/draft is the intended target. A nested $PWD
# (e.g. inside codegen/pitches) otherwise mis-resolves and the write-scope
# guard denies the legitimate pitch write. claude has no --cwd flag — cd + exec
# is the only reliable way (mirrors dispatch.sh).
resolve_pitch_root() {
    case "$1" in
    */codegen/pitches/*) printf '%s' "${1%%/codegen/pitches/*}" ;;
    */codegen/pitches) printf '%s' "${1%/codegen/pitches}" ;;
    *) printf '%s' "$1" ;;
    esac
}
PITCH_ROOT="$(resolve_pitch_root "$PWD")"
if [[ "$PITCH_ROOT" != "$PWD" ]]; then
    printf 'claude-experiment: launched inside codegen/pitches; using repo root %s\n' "$PITCH_ROOT" >&2
    cd "$PITCH_ROOT"
fi

source "$CODEGEN_DIR/harnesses/claude/load-role.sh"
load_role experiment

CONTEXT_FLAGS=()
TIER0_LOADED=""
if [[ -f "./PROJECT_CONTEXT.md" ]]; then
    CONTEXT_FLAGS+=(--append-system-prompt "$(cat ./PROJECT_CONTEXT.md)")
    # Tier 0: foundational docs listed under "## Always Load" in the index.
    # Read each basename, append context/<name> if it exists. Fail-open.
    _in_always=0
    while IFS= read -r _line; do
        case "$_line" in
        "## Always Load")
            _in_always=1
            continue
            ;;
        "## "*) [[ $_in_always -eq 1 ]] && break ;;
        esac
        [[ $_in_always -eq 1 ]] || continue
        case "$_line" in
        "- "*)
            _bn="${_line#- }"
            _bn="${_bn%% *}"
            [[ -n "$_bn" ]] || continue
            if [[ -f "./context/$_bn" ]]; then
                CONTEXT_FLAGS+=(--append-system-prompt "$(cat "./context/$_bn")")
                TIER0_LOADED="${TIER0_LOADED} ${_bn}"
            else
                printf 'claude-experiment: Tier-0 doc context/%s listed in Always Load but not found; skipping\n' "$_bn" >&2
            fi
            ;;
        esac
    done <./PROJECT_CONTEXT.md
fi

TOOL_FLAGS=()
if [ -n "$ROLE_TOOLS" ]; then
    TOOL_FLAGS+=(--tools "$ROLE_TOOLS")
elif [ -n "$ROLE_DISALLOWED" ]; then
    TOOL_FLAGS+=(--disallowed-tools "$ROLE_DISALLOWED")
fi

# Non-interactive: pass all non-interactive flags. Interactive: omit (claude handles tty detection).
NON_INTERACTIVE_FLAGS=()
if [[ -n "${CLAUDE_NONINTERACTIVE:-}" ]]; then
    NON_INTERACTIVE_FLAGS+=(
        --print
        --verbose
        --output-format stream-json
        --setting-sources project
        --strict-mcp-config
        --no-session-persistence
        --disable-slash-commands
    )
fi

# Basename resolver (strict) against $PWD/codegen/pitches/draft/
# 1. Contains / or ends in .md or contains space → pass through unchanged.
# 2. codegen/pitches/draft/<arg>.md exists → @-mention it.
# 3. Exactly one prefix match → @-mention it.
# 4. Multiple prefix matches → error + list + exit 1.
# 5. No match → error + exit 1.
RESOLVED_ARGS=()
RESOLVED_PITCHES=()
DRAFT_DIR="$PWD/codegen/pitches/draft"
for arg in "$@"; do
    if [[ "$arg" == */* ]] || [[ "$arg" == *.md ]] || [[ "$arg" == *" "* ]]; then
        RESOLVED_ARGS+=("$arg")
        continue
    fi
    if [[ -f "$DRAFT_DIR/${arg}.md" ]]; then
        RESOLVED_ARGS+=("@codegen/pitches/draft/${arg}.md")
        RESOLVED_PITCHES+=("$DRAFT_DIR/${arg}.md")
        continue
    fi
    matches=()
    if [[ -d "$DRAFT_DIR" ]]; then
        while IFS= read -r -d '' f; do
            bn="$(basename "$f" .md)"
            if [[ "$bn" == "${arg}"* ]]; then
                matches+=("$bn")
            fi
        done < <(find "$DRAFT_DIR" -maxdepth 1 -name "*.md" -print0 2>/dev/null)
    fi
    if [[ ${#matches[@]} -eq 1 ]]; then
        RESOLVED_ARGS+=("@codegen/pitches/draft/${matches[0]}.md")
        RESOLVED_PITCHES+=("$DRAFT_DIR/${matches[0]}.md")
    elif [[ ${#matches[@]} -gt 1 ]]; then
        printf 'claude-experiment: ambiguous basename %q; matches:\n' "$arg" >&2
        for m in "${matches[@]}"; do printf '  %s\n' "$m" >&2; done
        exit 1
    else
        printf 'claude-experiment: no draft matching %q in codegen/pitches/draft/\n' "$arg" >&2
        exit 1
    fi
done

# Derive EXP_SLUG for the worktree name.
# Priority: (1) resolved pitch basename; (2) first positional arg sanitized; (3) "session".
if [[ ${#RESOLVED_PITCHES[@]} -eq 1 ]]; then
    EXP_SLUG=$(basename "${RESOLVED_PITCHES[0]}" .md)
elif [[ $# -gt 0 ]]; then
    EXP_SLUG=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')
    [[ -z "$EXP_SLUG" ]] && EXP_SLUG="session"
else
    EXP_SLUG="session"
fi

# Export CLAUDE_PITCH_PATH when exactly one pitch was resolved from draft/
# Gives /ready command a stable absolute path independent of cwd at invocation time.
if [[ ${#RESOLVED_PITCHES[@]} -eq 1 ]]; then
    _pitch_basename="$(basename "${RESOLVED_PITCHES[0]}" .md)"
    export CLAUDE_PITCH_PATH="$(cd "$PWD" && pwd)/codegen/pitches/draft/${_pitch_basename}.md"
    # Tier 1: pitch-matched context files from § Domain Context Files table.
    # Parse the index, grep each row's identifiers against the resolved pitch. Fail-open.
    if [[ -f "$CLAUDE_PITCH_PATH" && -f "./PROJECT_CONTEXT.md" ]]; then
        _tier1_count=0
        _in_table=0
        while IFS='|' read -r _pre _file _domain _ids _rest; do
            # Detect table rows vs section headers
            case "$_file" in
            *"context/"*.md*)
                [[ $_in_table -eq 0 ]] && _in_table=1
                ;;
            *"File"* | *"---"*)
                continue
                ;;
            *)
                continue
                ;;
            esac
            # Strip backticks and whitespace from file path
            _ctx_file="${_file//\`/}"
            _ctx_file="${_ctx_file## }"
            _ctx_file="${_ctx_file%% }"
            # Extract just the basename
            _ctx_bn="${_ctx_file##*/}"
            # Skip if already Tier-0 loaded
            case "$TIER0_LOADED" in
            *" ${_ctx_bn}"*) continue ;;
            esac
            # Skip if file doesn't exist
            [[ -f "./${_ctx_file}" ]] || continue
            # Check if any identifier matches the pitch body (case-insensitive, fixed-string)
            _matched=0
            IFS=',' read -ra _id_arr <<<"$_ids"
            for _id in "${_id_arr[@]}"; do
                _id="${_id## }"
                _id="${_id%% }"
                [[ -z "$_id" ]] && continue
                if grep -qiF "$_id" "$CLAUDE_PITCH_PATH" 2>/dev/null; then
                    _matched=1
                    break
                fi
            done
            if [[ $_matched -eq 1 ]]; then
                if [[ $_tier1_count -lt 6 ]]; then
                    CONTEXT_FLAGS+=(--append-system-prompt "$(cat "./${_ctx_file}")")
                    _tier1_count=$((_tier1_count + 1))
                else
                    printf 'claude-experiment: Tier-1 cap (6) reached; skipping context/%s\n' "$_ctx_bn" >&2
                fi
            fi
        done <./PROJECT_CONTEXT.md
    fi
fi

# Cold-start: no args → open conversation directly
if [[ $# -eq 0 ]]; then
    exec claude \
        --settings '{"env":{"MAX_THINKING_TOKENS":"16000"}}' \
        "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
        --model "$ROLE_MODEL" \
        --effort "$ROLE_EFFORT" \
        --dangerously-skip-permissions \
        "${TOOL_FLAGS[@]+"${TOOL_FLAGS[@]}"}" \
        --system-prompt "$ROLE_SYSTEM_PROMPT" \
        "${CONTEXT_FLAGS[@]+"${CONTEXT_FLAGS[@]}"}" \
        --worktree "exp-$EXP_SLUG"
fi

exec claude \
    --settings '{"env":{"MAX_THINKING_TOKENS":"16000"}}' \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    --model "$ROLE_MODEL" \
    --effort "$ROLE_EFFORT" \
    --dangerously-skip-permissions \
    "${TOOL_FLAGS[@]+"${TOOL_FLAGS[@]}"}" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "${CONTEXT_FLAGS[@]+"${CONTEXT_FLAGS[@]}"}" \
    --worktree "exp-$EXP_SLUG" \
    "${RESOLVED_ARGS[@]+"${RESOLVED_ARGS[@]}"}"
