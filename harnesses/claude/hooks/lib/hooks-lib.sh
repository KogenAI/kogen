#!/bin/bash
# hooks-lib.sh — shared helper library for Claude Code hook scripts.
#
# Sourcing convention:
#   source "$(dirname "$0")/lib/hooks-lib.sh"
#
# What this library provides:
#   parse_input                  — read stdin once, populate exported vars (see contract below)
#   deny "<reason>"              — emit a PreToolUse permissionDecision: "deny" JSON envelope
#                                  to stdout. Caller should `exit 0` after.
#   block "<reason>"             — emit a Stop-event {"decision":"block","reason":...} JSON
#                                  envelope to stdout. Caller should `exit 0` after.
#   debug_log <slug> ...         — append a timestamped line to /tmp/<slug>-debug.log when
#                                  CODEGEN_HOOKS_DEBUG or per-slug overrides are set
#   hooks_realpath <path>        — pure-bash equivalent of `python3 os.path.realpath`,
#                                  handling non-existent paths via parent-walk fallback
#   session_log_from_transcript  — return the last codegen/logging/*.md path written by
#                                  this session, from $TRANSCRIPT_PATH. Empty if none.
#   pitch_from_transcript        — return the last codegen/pitches/*.md path written by
#                                  this session, from $TRANSCRIPT_PATH. Empty if none.
#                                  Exact mirror of session_log_from_transcript but matches
#                                  the codegen/pitches/.*\.md$ pattern.
#   read_tool_failures <dir>     — pretty-print durable tool-failure store under
#                                  <dir>/codegen/logging/failures/*.jsonl. Groups by tool.
#   read_gate_verdicts <dir>     — pretty-print durable gate-verdict history at
#                                  <dir>/codegen/logging/gate-verdicts.jsonl. Groups by verdict.
#
# Input contract (PreToolUse + SubagentStop + Stop fields, parse_input fills any
# field present on stdin and leaves the rest empty):
#   RAW_INPUT              — raw stdin string (preserve for ad-hoc jq queries)
#   TOOL_NAME              — .tool_name  (PreToolUse)
#   AGENT_TYPE             — .agent_type (PreToolUse / SubagentStart / SubagentStop)
#   AGENT_ID               — .agent_id   (PreToolUse / SubagentStop)
#   COMMAND                — .tool_input.command (Bash)
#   FILE_PATH              — .tool_input.file_path // .tool_input.notebook_path // .tool_input.path
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
    FILE_PATH=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // ""' 2>/dev/null)
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
# Active when CODEGEN_HOOKS_DEBUG is set OR when CODEGEN_<SLUG>_DEBUG
# is set (slug uppercased, hyphens → underscores). Output goes to
# /tmp/<slug>-debug.log. Errors are silently ignored — this is a diagnostic.
debug_log() {
    local slug="$1"
    shift
    local upper
    upper=$(printf '%s' "$slug" | tr 'a-z-' 'A-Z_')
    local per_slug_var="CODEGEN_${upper}_DEBUG"
    if [ -z "${CODEGEN_HOOKS_DEBUG:-}" ] && [ -z "${!per_slug_var:-}" ]; then
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

# repo_relative — convert a path to a repo-relative form.
#
# Given an absolute or relative path, returns the path relative to the repo root.
# The root is resolved as the git toplevel of the file's own containing directory
# (cwd-independent, via `git -C`). When git is unavailable or the path is not
# inside a git repo, falls back to stripping the launch cwd
# (CWD / CLAUDE_PROJECT_DIR / $PWD). If neither prefix matches, the canonicalised
# path is returned as-is (absolute).
#
# Usage: rel=$(repo_relative "$FILE_PATH")
repo_relative() {
    local path="$1"
    # Relative paths are already repo-relative — pass through unchanged.
    case "$path" in
    /*) ;;
    *)
        printf '%s\n' "$path"
        return 0
        ;;
    esac
    local canonical
    canonical=$(hooks_realpath "$path") || return 1

    # Prefer the git toplevel of the file's own directory — cwd-independent.
    # Walk up to the first EXISTING ancestor (the file itself may not exist yet
    # on a fresh Write), then ask git from there with -C.
    local probe_dir
    probe_dir=$(dirname "$canonical")
    while [ -n "$probe_dir" ] && [ ! -d "$probe_dir" ]; do
        local parent
        parent=$(dirname "$probe_dir")
        [ "$parent" = "$probe_dir" ] && break
        probe_dir="$parent"
    done
    if [ -d "$probe_dir" ]; then
        local toplevel
        toplevel=$(git -C "$probe_dir" rev-parse --show-toplevel 2>/dev/null) || toplevel=""
        if [ -n "$toplevel" ]; then
            toplevel=$(hooks_realpath "$toplevel") || toplevel=""
        fi
        if [ -n "$toplevel" ]; then
            case "$toplevel" in
            */) ;;
            *) toplevel="${toplevel}/" ;;
            esac
            case "$canonical" in
            "${toplevel}"*)
                printf '%s\n' "${canonical#"$toplevel"}"
                return 0
                ;;
            esac
        fi
    fi

    # Fallback: strip the launch cwd (preserves every case that works today).
    local raw_cwd="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    local cwd_prefix
    cwd_prefix=$(hooks_realpath "$raw_cwd") || cwd_prefix="$raw_cwd"
    case "$cwd_prefix" in
    */) ;;
    *) cwd_prefix="${cwd_prefix}/" ;;
    esac
    case "$canonical" in
    "${cwd_prefix}"*) printf '%s\n' "${canonical#"$cwd_prefix"}" ;;
    *) printf '%s\n' "$canonical" ;;
    esac
}

# session_log_from_transcript — return the last codegen/logging/*.md path written
# by this session, derived from $TRANSCRIPT_PATH (set by parse_input).
#
# Reads TRANSCRIPT_PATH as a JSONL file (one JSON object per line). Filters
# assistant tool_use entries with name in {Write, Edit, MultiEdit} whose
# input.file_path matches the pattern codegen/logging/.*\.md$. Outputs the
# LAST matching file_path (tail -n 1 semantics — most recent write in
# transcript order). Empty result when:
#   - TRANSCRIPT_PATH is unset or empty
#   - TRANSCRIPT_PATH does not exist or is not readable
#   - No matching tool_use entries found
# jq errors are swallowed via 2>/dev/null. No --slurp (streams line-by-line).
session_log_from_transcript() {
    local result=""
    # Run the transcript jq scan only when TRANSCRIPT_PATH is usable. When it is
    # empty/unset/unreadable, skip the scan but FALL THROUGH to the disk fallback
    # below (managed builds with a lagging or absent transcript still resolve).
    if [ -n "${TRANSCRIPT_PATH:-}" ] && [ -r "$TRANSCRIPT_PATH" ]; then
        result=$(jq -r '
        .message.content[]?
        | select(.type == "tool_use"
            and (.name == "Write" or .name == "Edit" or .name == "MultiEdit"))
        | select(.input.file_path | test("codegen/logging/.*\\.md$"))
        | .input.file_path
    ' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)
    fi
    # Filesystem fallback for managed build sessions where the transcript file
    # lags the live stream (print-mode builds flush the transcript asynchronously).
    # Also fires when the transcript yields a path that no longer exists on disk
    # (stale/lagging transcript pointing at an old log). In both cases, consult
    # the disk under managed-build conditions.
    # Interactive sessions keep strict transcript-bound resolution — if neither
    # inner branch assigns, result stays empty/stale → caller denies.
    if [ -z "$result" ] || [ ! -e "$result" ]; then
        # A stale (non-existent) transcript path must not block the disk scan.
        [ -n "$result" ] && [ ! -e "$result" ] && result=""
        local apps_root="${OCG_APPS_ROOT:-}"
        local cwd="${CWD:-$PWD}"
        if [ -n "$apps_root" ]; then
            case "$cwd" in
            "${apps_root%/}"/*)
                result=$(ls -t "$cwd/codegen/logging"/*.md 2>/dev/null | head -1)
                ;;
            esac
        fi
        # Non-interactive managed builds (CODEGEN_BUILD_NON_INTERACTIVE, set by
        # dispatch.sh) run with cwd already at the app dir but may sit outside
        # OCG_APPS_ROOT (e.g. codegen self-build). Slow-flushing Node runtimes
        # (Node 20 on a drifted box) let the hook fire before the step-log Write
        # lands in the transcript, so the strict transcript scan above returns
        # empty and the planner-spawn gate fails closed -> deadlock spiral.
        # Scan the logging dir by mtime as a parity twin to the Pi handler
        # (step-log-section-before-spawn.ts getActiveStepLog). Still fail-closed:
        # an empty/absent logging dir yields empty result -> caller denies.
        if [ -z "$result" ] && [ -n "${CODEGEN_BUILD_NON_INTERACTIVE:-}" ]; then
            result=$(ls -t "$cwd/codegen/logging"/*.md 2>/dev/null | head -1)
        fi
    fi
    printf '%s' "$result"
}

# pitch_from_transcript — return the last codegen/pitches/*.md path written
# by this session, derived from $TRANSCRIPT_PATH (set by parse_input).
#
# Exact mirror of session_log_from_transcript but matches the pattern
# codegen/pitches/.*\.md$ instead of codegen/logging/.*\.md$. Returns
# the LAST matching file_path (tail -n 1 semantics — most recent write in
# transcript order). Empty result when:
#   - TRANSCRIPT_PATH is unset or empty
#   - TRANSCRIPT_PATH does not exist or is not readable
#   - No matching tool_use entries found
# jq errors are swallowed via 2>/dev/null. No --slurp (streams line-by-line).
pitch_from_transcript() {
    if [ -z "${TRANSCRIPT_PATH:-}" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
        printf ''
        return 0
    fi
    jq -r '
        .message.content[]?
        | select(.type == "tool_use"
            and (.name == "Write" or .name == "Edit" or .name == "MultiEdit"))
        | select(.input.file_path | test("codegen/pitches/.*\\.md$"))
        | .input.file_path
    ' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1
}

# require_inspector_agent_type — guard for inspector-only hooks.
# If AGENT_TYPE is set and is NOT one of the known inspector values,
# exit 0 (allow the tool, not our responsibility). If AGENT_TYPE is unset
# (outer session, not a subagent), exit 0. If AGENT_TYPE matches an inspector
# identity, return (continue to hook logic). This pattern prevents
# inspector-scoped hooks from firing in non-inspector contexts.
require_inspector_agent_type() {
    case "${AGENT_TYPE:-}" in
    inspector | inspector-phoenix) return 0 ;;
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

# read_tool_failures <project_dir> — pretty-print the durable tool-failure
# store under <project_dir>/codegen/logging/failures/*.jsonl.
# Aggregates tool × count with the latest error + session. Newest-first.
# Empty/absent store → prints "no tool failures recorded" and returns 0.
# Malformed JSONL lines are skipped (jq fromjson? // empty).
read_tool_failures() {
    local project_dir="$1"
    local dir="$project_dir/codegen/logging/failures"
    if ! ls "$dir"/*.jsonl >/dev/null 2>&1; then
        printf 'no tool failures recorded\n'
        return 0
    fi
    cat "$dir"/*.jsonl 2>/dev/null |
        jq -rR 'fromjson? // empty' 2>/dev/null |
        jq -rs '
            group_by(.tool)
            | map({tool: .[0].tool, count: length,
                   latest_error: (sort_by(.ts) | last | .error),
                   latest_ts: (map(.ts) | max)})
            | sort_by(.latest_ts) | reverse
            | (["TOOL","COUNT","LATEST_ERROR"] | @tsv),
              (.[] | [.tool, (.count|tostring),
                      (.latest_error | .[0:60])] | @tsv)
        ' 2>/dev/null
}

# read_gate_verdicts <project_dir> — pretty-print the durable gate-verdict
# history under <project_dir>/codegen/logging/gate-verdicts.jsonl.
# Aggregates verdict × count (clear/failed/inconclusive). Newest-first by ts.
# Empty/absent store → prints "no gate verdicts recorded" and returns 0.
read_gate_verdicts() {
    local project_dir="$1"
    local file="$project_dir/codegen/logging/gate-verdicts.jsonl"
    if [ ! -f "$file" ]; then
        printf 'no gate verdicts recorded\n'
        return 0
    fi
    jq -rR 'fromjson? // empty' "$file" 2>/dev/null |
        jq -rs '
            group_by(.verdict)
            | map({verdict: .[0].verdict, count: length,
                   latest_ts: (map(.ended) | max)})
            | sort_by(.latest_ts) | reverse
            | (["VERDICT","COUNT","LATEST"] | @tsv),
              (.[] | [.verdict, (.count|tostring), .latest_ts] | @tsv)
        ' 2>/dev/null
}
