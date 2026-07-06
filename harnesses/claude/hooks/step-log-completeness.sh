#!/usr/bin/env bash
# step-log-completeness.sh — Stop hook that blocks the orchestrator from
# stopping if the delegation cycle is incomplete.
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Cycle-state.json is the sole authority. Fast-path behavior:
#   COMMITTED (terminal)  → allow
#   REVIEWED              → block (context-curator not yet run)
#   CURATED               → block (committer not yet run)
#   GATED + verdict=clear → block (reviewer not yet run)
#   GATED + other verdict → allow (gate failure handled by phoenix-dev-gate re-spawn)
#   absent/mismatched     → allow (fail-open)
#
# Skip when:
#   - STOP_HOOK_ACTIVE=true (recursion guard)
#   - No active step log found
#   - INCONCLUSIVE ⚠️ appears in the log (orchestrator in INCONCLUSIVE recovery mode)
#   - Last assistant message indicates async wait (ScheduleWakeup, in flight, still running)
#   - Last assistant message matches intent regex (asking user a question)

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/cycle-state.sh"
parse_input

session_id="${SESSION_ID:-unknown}"
project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"

debug_log step-log-completeness "session=$session_id"

# Loop guard
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log step-log-completeness "skip: stop_hook_active"
    exit 0
fi

# Investigative-mode skip: this build-runtime gate enforces ONLY in build mode.
# Skip (exit 0) for any investigative role (shape/debug/ops/experiment/refactor)
# via is_build_mode() — mirrors signal: CLAUDE_ROLE_FAMILY.
source "$(dirname "$0")/_role.sh"
is_build_mode || {
    debug_log step-log-completeness "skip: investigative role=$(resolve_role)"
    exit 0
}

# Intent guard: orchestrator is asking the user something — let it stop.
# Only honor in INTERACTIVE sessions; headless builds fall through to block.
trimmed=$(printf '%s' "$LAST_ASSISTANT_MESSAGE" | sed -E 's/[[:space:]]+$//')
last_char="${trimmed: -1}"
intent_regex='[Ss]hould I|[Nn]eed clarification|[Bb]locked|[Ss]tuck|[Ww]aiting for|[Pp]lease confirm|[Ww]ant me to|[Cc]onfirm before'
if [ -z "${CODEGEN_BUILD_NON_INTERACTIVE:-}" ]; then
    if [ "$last_char" = "?" ] || printf '%s' "$LAST_ASSISTANT_MESSAGE" | grep -qE "$intent_regex"; then
        debug_log step-log-completeness "skip: intent question detected"
        exit 0
    fi
else
    debug_log step-log-completeness "headless: intent escape suppressed (CODEGEN_BUILD_NON_INTERACTIVE set) — falling through to block logic"
fi

# Async-wait guard: orchestrator is yielding for a background event.
if printf '%s' "$LAST_ASSISTANT_MESSAGE" | grep -qE 'ScheduleWakeup|scheduled.*wakeup|checking back in|seed rebuild|still running|in flight'; then
    debug_log step-log-completeness "skip: async-wait signal in last message"
    exit 0
fi

# Locate the active step log from the session transcript.
log_file=$(session_log_from_transcript)

if [ -z "$log_file" ] || [ ! -r "$log_file" ]; then
    debug_log step-log-completeness "skip: no active step log"
    exit 0
fi

debug_log step-log-completeness "log=$log_file"

# Skip when an inconclusive gate event is present — orchestrator is in
# recovery mode.
if jq -e 'select(.ev=="gate" and .verdict=="inconclusive")' "$log_file" >/dev/null 2>&1; then
    debug_log step-log-completeness "skip: INCONCLUSIVE gate event in log"
    exit 0
fi

# Skip when a death event is present — orchestrator is mid-recovery.
if jq -e 'select(.ev=="died")' "$log_file" >/dev/null 2>&1; then
    debug_log step-log-completeness "skip: death event in log (in recovery)"
    exit 0
fi

# _role_body_floor <log_file> <role> — concatenates every role event body for
# the given role (decoded from the JSONL cycle log, in call order), skipping
# blank lines and ### retro blocks. Blocks if the concatenated body is empty
# (suspected death — the role appears to have produced no real content).
_role_body_floor() {
    local _lf="$1"
    local _role="$2"
    if ! jq -e --arg r "$_role" 'select(.ev=="role" and .role==$r)' "$_lf" >/dev/null 2>&1; then
        return 0
    fi
    local _body
    _body=$(jq -r --arg r "$_role" 'select(.ev=="role" and .role==$r)|.body' "$_lf" 2>/dev/null | awk '
        /^### What I Learned/ { in_retro=1; next }
        in_retro && /^[[:space:]]*$/ { next }
        in_retro && /^[[:space:]]*[-*]/ { next }
        in_retro { in_retro=0 }
        !/^###/ { print }
    ' | grep -v '^[[:space:]]*$')
    if [ -z "$_body" ]; then
        block "step-log-completeness: role '$_role' has no real body — the role appears to have died mid-response (empty or status-line-only body). Recover: write the INTERRUPTED/ABORTED death stamp and re-spawn the dead role, OR mark the stage ABORTED 💀 and halt. Do not advance the cycle past a dead stage. Step log: $_lf"
        exit 0
    fi
}

# ── Cycle-state fast-path ──────────────────────────────────────────────────
# cycle-state.json is authoritative when present AND step_log matches active log.
cs_step=$(cycle_state_step_log "$project_dir")
cs_state=$(cycle_state_get "$project_dir")
if [ -n "$cs_state" ] && [ "$cs_step" = "$log_file" ]; then
    debug_log step-log-completeness "cycle-state=$cs_state step=$log_file (matched)"

    if cycle_state_is_terminal "$cs_state"; then
        # Full cycle done — committer ran; allow stop.
        debug_log step-log-completeness "skip: cycle-state=$cs_state terminal — full cycle done"
        exit 0
    fi
    next=$(cycle_state_next "$cs_state")
    if [ -n "$next" ]; then
        role=$(cycle_state_role "$cs_state")
        debug_log step-log-completeness "BLOCK: cycle-state=$cs_state — $role not yet run"
        case "$cs_state" in
        REVIEWED)
            # Content-floor: reviewer role event must have a real body.
            _floor_role=$(jq -r 'select(.ev=="role" and (.role | startswith("reviewer-")))|.role' "$log_file" 2>/dev/null | tail -n 1)
            if [ -n "$_floor_role" ]; then
                _role_body_floor "$log_file" "$_floor_role"
            fi
            block "step-log-completeness: reviewer finished (cycle-state=REVIEWED) but context-curator has not run yet. Continue the cycle: delegate to context-curator, then committer. Step log: $log_file"
            ;;
        CURATED)
            # Content-floor: context-curator role event must have a real body.
            _role_body_floor "$log_file" "context-curator"
            block "step-log-completeness: context-curator finished (cycle-state=CURATED) but committer has not run yet. Continue the cycle: delegate to committer. Step log: $log_file"
            ;;
        GATED)
            verdict=$(cycle_state_verdict "$project_dir")
            if [ "$verdict" = "clear" ]; then
                # Content-floor: developer role event must have a real body when gate cleared.
                _floor_role=$(jq -r 'select(.ev=="role" and (.role | startswith("developer-")))|.role' "$log_file" 2>/dev/null | tail -n 1)
                if [ -n "$_floor_role" ]; then
                    _role_body_floor "$log_file" "$_floor_role"
                fi
                block "step-log-completeness: developer gate cleared (ALL CLEAR ✅) but reviewer has not run yet. Continue the cycle: delegate to reviewer-phoenix, then context-curator, then committer. Step log: $log_file"
            else
                debug_log step-log-completeness "skip: GATED verdict=$verdict — gate failure handled by phoenix-dev-gate re-spawn"
                exit 0
            fi
            ;;
        *)
            block "step-log-completeness: cycle incomplete (cycle-state=$cs_state). Continue the cycle: delegate to $role. Step log: $log_file"
            ;;
        esac
        exit 0
    fi
fi

exit 0
