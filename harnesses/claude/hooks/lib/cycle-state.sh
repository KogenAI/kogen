#!/usr/bin/env bash
# cycle-state.sh — Shared helper for writing/reading the explicit cycle-state
# record codegen/gate-pending/cycle-state.json. Modeled on gate-result.sh.
#
# States: GATED → REVIEWED → CURATED → COMMITTED  (SHIPPED = disk state, not JSON)
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
