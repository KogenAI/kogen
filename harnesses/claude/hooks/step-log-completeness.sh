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

# Investigative-mode skip: this build-runtime gate enforces ONLY in build mode
# (empty role). Skip (exit 0) for any non-empty investigative role (shape/debug/
# ops/experiment) — mirrors signal: CLAUDE_ROLE_FAMILY. Inverse of pitch-format-validator.
source "$(dirname "$0")/_role.sh"
role=$(resolve_role)
if [ -n "$role" ]; then
    debug_log step-log-completeness "skip: investigative role=$role"
    exit 0
fi

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

# Skip when INCONCLUSIVE is present — orchestrator is in recovery mode.
if grep -qE 'INCONCLUSIVE ⚠️' "$log_file" 2>/dev/null; then
    debug_log step-log-completeness "skip: INCONCLUSIVE in log"
    exit 0
fi

# Skip when a death marker is present — orchestrator is mid-recovery.
if grep -qF '### INTERRUPTED ⚠️' "$log_file" 2>/dev/null || grep -qF '### ABORTED 💀' "$log_file" 2>/dev/null; then
    debug_log step-log-completeness "skip: death marker in log (in recovery)"
    exit 0
fi

# _section_body_floor <log_file> <section_header>
# Extracts the body of the named section, skipping blank lines and ### retro blocks.
# Blocks if body is empty OR a single line shorter than 40 chars (suspected death).
_section_body_floor() {
    local _lf="$1"
    local _hdr="$2"
    if ! grep -qF "$_hdr" "$_lf" 2>/dev/null; then
        return 0
    fi
    local _body
    _body=$(awk -v header="$_hdr" '
        found && /^## / { exit }
        found && /^### What I Learned/ { skip_retro=1 }
        found && skip_retro && /^### / && !/^### What I Learned/ { skip_retro=0 }
        found && !skip_retro && !/^###/ { print }
        $0 == header { found=1 }
    ' "$_lf" 2>/dev/null | grep -v '^[[:space:]]*$')
    if [ -z "$_body" ]; then
        block "step-log-completeness: '$_hdr' has no real body — the role appears to have died mid-response (empty or status-line-only section). Recover: write the INTERRUPTED/ABORTED death stamp and re-spawn the dead role, OR mark the stage ABORTED 💀 and halt. Do not advance the cycle past a dead stage. Step log: $_lf"
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
            # Content-floor: reviewer section must have a real body.
            _floor_hdr=$(grep -m1 '^## reviewer-' "$log_file" 2>/dev/null || true)
            if [ -n "$_floor_hdr" ]; then
                _section_body_floor "$log_file" "$_floor_hdr"
            fi
            block "step-log-completeness: reviewer finished (cycle-state=REVIEWED) but context-curator has not run yet. Continue the cycle: delegate to context-curator, then committer. Step log: $log_file"
            ;;
        CURATED)
            # Content-floor: context-curator section must have a real body.
            _section_body_floor "$log_file" "## context-curator Section"
            block "step-log-completeness: context-curator finished (cycle-state=CURATED) but committer has not run yet. Continue the cycle: delegate to committer. Step log: $log_file"
            ;;
        GATED)
            verdict=$(cycle_state_verdict "$project_dir")
            if [ "$verdict" = "clear" ]; then
                # Content-floor: developer section must have a real body when gate cleared.
                _floor_hdr=$(grep -m1 '^## developer-' "$log_file" 2>/dev/null || true)
                if [ -n "$_floor_hdr" ]; then
                    _section_body_floor "$log_file" "$_floor_hdr"
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
