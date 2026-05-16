#!/bin/bash
# hooks-lib.sh — shared helper library for Claude Code hook scripts.
#
# Sourcing convention:
#   source "$(dirname "$0")/lib/hooks-lib.sh"
#
# What this library provides:
#   parse_input          — read stdin once, populate exported vars (see contract below)
#   deny "<reason>"      — emit a PreToolUse permissionDecision: "deny" JSON envelope
#                          to stdout. Caller should `exit 0` after.
#   block "<reason>"     — emit a Stop-event {"decision":"block","reason":...} JSON
#                          envelope to stdout. Caller should `exit 0` after.
#   debug_log <slug> ...  — append a timestamped line to /tmp/<slug>-debug.log when
#                          COMBOBULATE_HOOKS_DEBUG or per-slug overrides are set
#   hooks_realpath <path> — pure-bash equivalent of `python3 os.path.realpath`,
#                          handling non-existent paths via parent-walk fallback
#
# Input contract (PreToolUse + SubagentStop + Stop fields, parse_input fills any
# field present on stdin and leaves the rest empty):
#   RAW_INPUT              — raw stdin string (preserve for ad-hoc jq queries)
#   TOOL_NAME              — .tool_name  (PreToolUse)
#   AGENT_TYPE             — .agent_type (PreToolUse / SubagentStart / SubagentStop)
#   AGENT_ID               — .agent_id   (PreToolUse / SubagentStop)
#   COMMAND                — .tool_input.command (Bash)
#   FILE_PATH              — .tool_input.file_path // .tool_input.notebook_path
#   CWD                    — .cwd        (PreToolUse / SubagentStop / Stop)
#   SESSION_ID             — .session_id (Stop / SubagentStop)
#   STOP_HOOK_ACTIVE       — .stop_hook_active // false
#   LAST_ASSISTANT_MESSAGE — .last_assistant_message
#   TRANSCRIPT_PATH        — .transcript_path
#   PROMPT                 — .prompt (UserPromptSubmit / SubagentStart)
#
# All exported vars default to "" if absent on stdin. Callers should still
# treat any field as possibly empty — for example, AGENT_TYPE is "" for
# orchestrator-level PreToolUse calls.

set -u

# parse_input — populate exported vars from JSON-on-stdin.
# Reads stdin once into RAW_INPUT, then runs a single jq invocation that
# emits each field on its own line in a fixed order. We re-read stdin via
# RAW_INPUT to avoid a second jq call per field.
parse_input() {
    RAW_INPUT=$(cat)
    export RAW_INPUT

    # Single jq invocation that prints each field on a line. Use @sh to
    # protect newlines and special chars; we then read line by line.
    # NOTE: we rely on `jq -r` — fields containing literal newlines will
    # break this scheme. Hook inputs from Claude Code do not contain
    # multi-line tool_input.command values often enough to justify the
    # extra cost of @json + jq per field; revisit if a hook breaks.
    # Per-field jq calls — slightly more expensive than a single multi-output
    # call, but preserves embedded newlines in fields like PROMPT,
    # LAST_ASSISTANT_MESSAGE, and tool_input.command (heredocs).
    TOOL_NAME=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
    AGENT_TYPE=$(printf '%s' "$RAW_INPUT" | jq -r '.agent_type // ""' 2>/dev/null)
    AGENT_ID=$(printf '%s' "$RAW_INPUT" | jq -r '.agent_id // ""' 2>/dev/null)
    COMMAND=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
    FILE_PATH=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
    CWD=$(printf '%s' "$RAW_INPUT" | jq -r '.cwd // ""' 2>/dev/null)
    SESSION_ID=$(printf '%s' "$RAW_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
    STOP_HOOK_ACTIVE=$(printf '%s' "$RAW_INPUT" | jq -r '.stop_hook_active // false | tostring' 2>/dev/null)
    LAST_ASSISTANT_MESSAGE=$(printf '%s' "$RAW_INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null)
    TRANSCRIPT_PATH=$(printf '%s' "$RAW_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
    PROMPT=$(printf '%s' "$RAW_INPUT" | jq -r '.prompt // ""' 2>/dev/null)

    export TOOL_NAME AGENT_TYPE AGENT_ID COMMAND FILE_PATH CWD \
        SESSION_ID STOP_HOOK_ACTIVE LAST_ASSISTANT_MESSAGE TRANSCRIPT_PATH PROMPT
}

# deny <reason> — emit PreToolUse permissionDecision:"deny" JSON envelope.
# The caller should `exit 0` after invoking this; Claude Code reads the JSON
# from stdout to determine the deny action. Reason is surfaced to the model
# via permissionDecisionReason.
deny() {
    local reason="$1"
    jq -n --arg reason "$reason" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $reason
        }
    }'
}

# block <reason> — emit Stop-event {"decision":"block","reason":...} JSON.
# Used by stop-resume.sh and stop-cycle-guard.sh to inject a synthetic
# user turn after the orchestrator/subagent stops. Caller should `exit 0`.
block() {
    local reason="$1"
    jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
}

# debug_log <slug> <fields...> — append a timestamped debug line.
# Active when COMBOBULATE_HOOKS_DEBUG is set OR when COMBOBULATE_<SLUG>_DEBUG
# is set (slug uppercased, hyphens → underscores). Output goes to
# /tmp/<slug>-debug.log. Errors are silently ignored — this is a diagnostic.
debug_log() {
    local slug="$1"
    shift
    local upper
    upper=$(printf '%s' "$slug" | tr 'a-z-' 'A-Z_')
    local per_slug_var="COMBOBULATE_${upper}_DEBUG"
    if [ -z "${COMBOBULATE_HOOKS_DEBUG:-}" ] && [ -z "${!per_slug_var:-}" ]; then
        return 0
    fi
    printf '%s %s %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$slug" \
        "$*" \
        >>"/tmp/${slug}-debug.log" 2>/dev/null || true
}

# hooks_realpath <path> — resolve to an absolute, symlink-free path.
# Pure bash + cd/pwd -P trick. For non-existent paths, walks up parents
# until an existing directory is found, then re-appends the unresolved
# tail. Equivalent to `python3 -c "import os; print(os.path.realpath(p))"`
# for the cases this codebase exercises.
hooks_realpath() {
    local p="$1"
    [ -z "$p" ] && {
        printf ''
        return 0
    }

    # If the path already exists, the cd-basename trick is enough.
    if [ -e "$p" ]; then
        if [ -d "$p" ]; then
            (cd "$p" 2>/dev/null && pwd -P)
            return $?
        fi
        local dir base
        dir=$(dirname "$p")
        base=$(basename "$p")
        local resolved_dir
        resolved_dir=$(cd "$dir" 2>/dev/null && pwd -P)
        if [ -z "$resolved_dir" ]; then
            printf '%s' "$p"
            return 0
        fi
        # If it's a symlink to a file, resolve the target.
        if [ -L "$p" ]; then
            local target
            target=$(readlink "$p")
            case "$target" in
            /*)
                hooks_realpath "$target"
                return
                ;;
            *)
                hooks_realpath "$resolved_dir/$target"
                return
                ;;
            esac
        fi
        printf '%s/%s' "$resolved_dir" "$base"
        return 0
    fi

    # Non-existent path: walk up parents until one exists, then re-append
    # the tail.
    local tail=""
    local cur="$p"
    # Make absolute first so dirname behaves predictably.
    case "$cur" in
    /*) ;;
    *) cur="$PWD/$cur" ;;
    esac

    while [ -n "$cur" ] && [ ! -e "$cur" ]; do
        local base
        base=$(basename "$cur")
        if [ -z "$tail" ]; then
            tail="$base"
        else
            tail="$base/$tail"
        fi
        local parent
        parent=$(dirname "$cur")
        if [ "$parent" = "$cur" ]; then
            # Reached / and still nothing exists — return as-is.
            printf '%s' "$p"
            return 0
        fi
        cur="$parent"
    done

    local resolved_existing
    if [ -d "$cur" ]; then
        resolved_existing=$(cd "$cur" 2>/dev/null && pwd -P)
    else
        resolved_existing=$(hooks_realpath "$cur")
    fi

    if [ -z "$resolved_existing" ]; then
        printf '%s' "$p"
        return 0
    fi

    if [ -z "$tail" ]; then
        printf '%s' "$resolved_existing"
    elif [ "$resolved_existing" = "/" ]; then
        printf '/%s' "$tail"
    else
        printf '%s/%s' "$resolved_existing" "$tail"
    fi
}

# require_inspector_agent_type — guard for inspector-only hooks.
# If AGENT_TYPE is set and is NOT one of the known inspector values,
# exit 0 (allow the tool, not our responsibility). If AGENT_TYPE is unset
# (outer session, not a subagent), exit 0. If AGENT_TYPE matches an inspector
# identity, return (continue to hook logic). This pattern prevents
# inspector-scoped hooks from firing in non-inspector contexts.
require_inspector_agent_type() {
    case "${AGENT_TYPE:-}" in
    inspector | inspector-phoenix | codex-inspector | cursor-inspector) return 0 ;;
    *) exit 0 ;;
    esac
}

# is_subagent — true if AGENT_TYPE is set (inner subagent invocation).
# Used to gate outer-session-only constraints that must NOT apply to subagents.
is_subagent() {
    [ -n "${AGENT_TYPE:-}" ]
}

# is_outer_session — true if AGENT_TYPE is unset (orchestrator-level call).
# Inverse of is_subagent; explicit name for readability.
is_outer_session() {
    [ -z "${AGENT_TYPE:-}" ]
}
