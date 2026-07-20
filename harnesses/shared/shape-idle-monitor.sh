#!/usr/bin/env bash
# shape-idle-monitor.sh — advisory liveness monitor for an interactive
# claude-shape REPL. NOT a hook (registered on no event); launcher-support,
# lives in harnesses/shared/ per repo convention.
#
# Forked (backgrounded, detached) from claude-shape.sh BEFORE `exec claude`,
# because $$ survives exec and becomes the REPL's PID. The monitor is
# reparented away from claude and is NOT its child — nothing else will ever
# reap it, so the `kill -0` self-terminate check is load-bearing, not hygiene.
#
# Binds to its own session transcript via a filename set-diff against a
# pre-exec snapshot (claude does not hold the transcript file open, so this
# cannot be done via fd/lsof scan). Ambiguous binding (0 or >=2 new files —
# e.g. a concurrent codegen-build loop writing the same project dir) ->
# exits silently forever rather than risk warning on a stranger's session.
#
# Every 30s: if the watched PID is dead -> exit. If the transcript mtime
# advanced -> progress, reset+rearm. If frozen past the warn threshold AND
# the last timestamped entry is not from the assistant -> a response is
# owed and nothing is happening -> bell + banner on the REPL's terminal.
# Warns once per stall; never kills unless CODEGEN_SHAPE_IDLE_KILL=1.
#
# Args: <watch_pid> <project_dir> <snapshot_file>
#   watch_pid:     PID to monitor (the exec'd claude REPL == pre-exec $$)
#   project_dir:   $HOME/.claude/projects/<slug> holding this session's *.jsonl
#   snapshot_file: file listing *.jsonl basenames present before the exec
#
# Env knobs (both optional, genuinely-optional tuning — not masking
# defaults; the default IS the intended warn-only behavior):
#   CODEGEN_SHAPE_IDLE_WARN_SECS  — freeze duration before warning (default 600)
#   CODEGEN_SHAPE_IDLE_KILL       — "1" to SIGTERM the REPL after warning (default: never)
#
# Fail-open by design (sanctioned optional-observability carve-out): this
# monitor guards nothing, denies nothing, returns no verdict. Any failure to
# bind/resolve/write reproduces exactly today's behavior (an undetected
# hang) rather than a wrong action — so every non-happy path is a silent
# `exit 0`, never stderr noise on the operator's live terminal.
#
# Test-only knob: MAX_ITERS bounds the poll loop so tests run fast without
# real 30s sleeps. Unset in production (infinite loop).

set -uo pipefail # NOTE: no -e — every step here is fail-open

WATCH="${1:-}"
PROJECT_DIR="${2:-}"
SNAPSHOT_FILE="${3:-}"

[[ -n "$WATCH" && -n "$PROJECT_DIR" && -n "$SNAPSHOT_FILE" ]] || exit 0

WARN_SECS="${CODEGEN_SHAPE_IDLE_WARN_SECS:-600}"
# POLL_SECS is 30s in production. Test-only override via _SHAPE_IDLE_POLL_SECS
# keeps the poll cadence real (matters for MAX_ITERS-bounded tests) without
# forcing every test to burn 30s per iteration.
POLL_SECS="${_SHAPE_IDLE_POLL_SECS:-30}"

# ── mtime: GNU-first with BSD fallback (context/development.md § stat portability) ──
_mtime() {
    stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0
}

# ── bind to the single new transcript; ambiguous -> exit silent forever ──
_bind_transcript() {
    [[ -d "$PROJECT_DIR" ]] || return 1
    [[ -f "$SNAPSHOT_FILE" ]] || return 1
    local before after new_count new_file f bn
    before="$SNAPSHOT_FILE"
    after=$(mktemp 2>/dev/null) || return 1
    : >"$after"
    for f in "$PROJECT_DIR"/*.jsonl; do
        [[ -e "$f" ]] || continue
        printf '%s\n' "$(basename "$f")" >>"$after"
    done
    new_count=0
    new_file=""
    while IFS= read -r bn; do
        [[ -n "$bn" ]] || continue
        if ! grep -qxF "$bn" "$before" 2>/dev/null; then
            new_count=$((new_count + 1))
            new_file="$bn"
        fi
    done <"$after"
    rm -f "$after" 2>/dev/null || true
    [[ "$new_count" -eq 1 ]] || return 1
    printf '%s' "$PROJECT_DIR/$new_file"
    return 0
}

# ── tty resolution: POSIX ps -o tty=, normalize macOS s000 vs Linux pts/0 ──
_resolve_tty() {
    local raw t
    raw=$(ps -o tty= -p "$WATCH" 2>/dev/null) || return 1
    t="${raw## }"
    t="${t%% }"
    [[ -n "$t" && "$t" != "?" && "$t" != "??" ]] || return 1
    if [[ -w "/dev/$t" ]]; then
        printf '%s' "/dev/$t"
        return 0
    fi
    if [[ -w "/dev/tty$t" ]]; then
        printf '%s' "/dev/tty$t"
        return 0
    fi
    return 1
}

# ── last timestamped entry's top-level "type" via jq ──
_last_entry_type() {
    jq -r 'select(.timestamp != null) | .type' "$1" 2>/dev/null | tail -n 1
}

TRANSCRIPT=""
for _attempt in 1 2 3; do
    TRANSCRIPT="$(_bind_transcript)" && break
    TRANSCRIPT=""
    sleep 1 2>/dev/null || true
done
[[ -n "$TRANSCRIPT" ]] || exit 0

LAST_MTIME=$(_mtime "$TRANSCRIPT")
FROZEN_SINCE=$(date +%s 2>/dev/null || echo 0)
ALREADY_WARNED=0

ITERS=0
while true; do
    # 1. Dead watch PID -> exit immediately. Must be first: nothing else reaps this process.
    kill -0 "$WATCH" 2>/dev/null || exit 0

    sleep "$POLL_SECS" 2>/dev/null || true

    CUR_MTIME=$(_mtime "$TRANSCRIPT")
    NOW=$(date +%s 2>/dev/null || echo 0)

    if [[ "$CUR_MTIME" != "$LAST_MTIME" ]]; then
        # Progress: reset the freeze timer and re-arm the warning.
        LAST_MTIME="$CUR_MTIME"
        FROZEN_SINCE="$NOW"
        ALREADY_WARNED=0
    else
        FROZEN=$((NOW - FROZEN_SINCE))
        if [[ "$FROZEN" -ge "$WARN_SECS" && "$ALREADY_WARNED" -eq 0 ]]; then
            LAST_TYPE="$(_last_entry_type "$TRANSCRIPT")"
            if [[ -n "$LAST_TYPE" && "$LAST_TYPE" != "assistant" ]]; then
                TTY="$(_resolve_tty)" && [[ -n "$TTY" ]] && {
                    OWED_AT=$(date -r "$FROZEN_SINCE" '+%H:%M:%S' 2>/dev/null || date '+%H:%M:%S' 2>/dev/null || echo "unknown")
                    FROZEN_MIN=$((FROZEN / 60))
                    {
                        printf '\a\n'
                        printf 'claude-shape: no response since %s — frozen %sm. This session is not thinking; it is stuck. Ctrl-C and relaunch.\n' "$OWED_AT" "$FROZEN_MIN"
                    } >"$TTY" 2>/dev/null || true
                    ALREADY_WARNED=1
                    if [[ "${CODEGEN_SHAPE_IDLE_KILL:-}" == "1" ]]; then
                        kill -TERM "$WATCH" 2>/dev/null || true
                    fi
                }
            fi
        fi
    fi

    if [[ -n "${MAX_ITERS:-}" ]]; then
        ITERS=$((ITERS + 1))
        [[ "$ITERS" -ge "$MAX_ITERS" ]] && exit 0
    fi
done
