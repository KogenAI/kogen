#!/usr/bin/env bash
# cycle-state.sh — Shared helper for writing/reading the explicit cycle-state
# record codegen/gate-pending/cycle-state.json. Modeled on gate-result.sh.
#
# States declared in CYCLE_STATE_ORDER below (single source of truth for ordering).
#
# Sourceable. After sourcing:
#   write_cycle_state <state> <step_log> <session_id> <verdict> <project_dir>
#       Writes codegen/gate-pending/cycle-state.json under <project_dir>.
#       <verdict> meaningful only for GATED (clear|failed|inconclusive); pass "" otherwise.
#   cycle_state_get <project_dir>       — prints .state or "" if absent/malformed.
#   cycle_state_step_log <project_dir>  — prints .step_log or "".
#   cycle_state_verdict <project_dir>   — prints .verdict or "".
#   cycle_state_session_id <project_dir>— prints .session_id or "".

set -u

write_cycle_state() {
    local state="$1"
    local step_log="$2"
    local session_id="$3"
    local verdict="$4"
    local project_dir="$5"
    local result_dir="$project_dir/codegen/gate-pending"
    mkdir -p "$result_dir"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n \
        --arg state "$state" \
        --arg step_log "$step_log" \
        --arg session_id "$session_id" \
        --arg verdict "$verdict" \
        --arg updated_at "$now" \
        '{
            state: $state,
            step_log: $step_log,
            session_id: $session_id,
            verdict: $verdict,
            updated_at: $updated_at
        }' >"$result_dir/cycle-state.json"
}

_cycle_state_field() {
    local project_dir="$1"
    local field="$2"
    local f="$project_dir/codegen/gate-pending/cycle-state.json"
    [ -f "$f" ] || {
        printf ''
        return 0
    }
    jq -r "(.${field}) // \"\"" "$f" 2>/dev/null || printf ''
}

cycle_state_get() { _cycle_state_field "$1" state; }
cycle_state_step_log() { _cycle_state_field "$1" step_log; }
cycle_state_verdict() { _cycle_state_field "$1" verdict; }
cycle_state_session_id() { _cycle_state_field "$1" session_id; }

# ── Ordering table (single source of truth) ────────────────────────────────
# Derive terminal state and successor from this list; NEVER hard-code
# "COMMITTED" or "CURATED" in callers — iterate instead.
CYCLE_STATE_ORDER="GATED REVIEWED CURATED COMMITTED"

# cycle_state_is_terminal <state>
#   Returns 0 (true) iff <state> is the last element of CYCLE_STATE_ORDER.
cycle_state_is_terminal() {
    local target="$1"
    local last=""
    local w
    for w in $CYCLE_STATE_ORDER; do
        last="$w"
    done
    [ "$target" = "$last" ]
}

# cycle_state_next <state>
#   Prints the successor state; prints nothing for terminal or unknown states.
cycle_state_next() {
    local target="$1"
    local prev=""
    local w
    for w in $CYCLE_STATE_ORDER; do
        if [ "$prev" = "$target" ]; then
            printf '%s' "$w"
            return 0
        fi
        prev="$w"
    done
    printf ''
}

# cycle_state_role <state>
#   Maps a non-terminal state to the human role name used in block messages.
#   REVIEWED → context-curator (the next agent after reviewer)
#   CURATED  → committer (the next agent after curator)
#   All others (GATED, COMMITTED, unknown) → ""
cycle_state_role() {
    local state="$1"
    case "$state" in
    REVIEWED) printf 'context-curator' ;;
    CURATED) printf 'committer' ;;
    *) printf '' ;;
    esac
}
