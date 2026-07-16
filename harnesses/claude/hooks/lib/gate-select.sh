#!/usr/bin/env bash
# gate-select.sh — deterministic decision tree for `dev-gate.sh`.
#
# Sourceable. After sourcing, call:
#
#   gate_select_decide <project_dir>
#
# It prints three lines to stdout:
#
#   gate=<command>
#   mode=<short|long>
#   timeout=<seconds>   (0 for short gates; the foreground poll budget for long gates)
#
# Inputs (in priority order):
#   1. The active step log's structured {"ev":"plan_gate",...} event, written
#      by the planner via `codegen-log append <role> --plan-gate @-`. If
#      present, planner wins — gate = its "command" field, mode/timeout from
#      its "mode"/"timeout" fields directly (no re-derivation).
#   2. Otherwise, per-app config `<project_dir>/.claude/gate-config.sh`, sourced
#      for a single required variable GATE_COMMAND. If GATE_COMMAND is non-empty,
#      gate = GATE_COMMAND (mode/timeout via gate_mode_for/gate_timeout_for).
#   3. Otherwise (no planner gate AND no GATE_COMMAND): FAIL LOUD. Print
#      `__GATE_UNRESOLVED__:<reason>` to stdout and return 0. There is NO
#      stack-guessing fallback and NO default gate — an unresolved gate is a
#      real misconfiguration the caller must surface (block / raise), never
#      silently skip.
#
# The gate SELECTION is a first-class JSONL event ({"ev":"plan_gate",...}) —
# never re-parsed out of the planner's free-form role body prose. See
# shared/rules/_core/session-log.md § the body is opaque, never re-parsed as
# structure.
#
# Per-app config contract (`<project_dir>/.claude/gate-config.sh`):
#   GATE_COMMAND — the exact gate command for this app (e.g. "make ci" for a
#                  Phoenix/static downstream app, "make test" for codegen itself).
#
# Mode selection from gate string (`gate_mode_for`):
#   contains "make llm" or "rebuild-seed-then" → long
#   anything else                              → short

set -u

# planner_body_from_log <step_log_file> — extract the concatenated planner
# role body text from a JSONL cycle log. The `## Plan`/`**Gate**:` prose
# scanners below operate on this DECODED body text, never on the raw JSONL
# bytes (a plan body containing "## Plan" is just a JSON string value, not a
# markdown structure). Multiple planner role events (re-runs) are joined with
# a newline, in call order (jq preserves file order). Empty string when the
# log is missing, unreadable, or carries no planner role event — callers fall
# through to their existing "no gate found" path exactly as before.
planner_body_from_log() {
    local log_file="$1"
    [ -f "$log_file" ] || {
        printf ''
        return 0
    }
    jq -r 'select(.ev == "role" and (.role | startswith("planner"))) | .body' \
        "$log_file" 2>/dev/null
}

# curator_learning_signal_from_log <step_log_file> — mechanical predicate
# for "does this cycle have anything for context-curator to curate?", read
# from the cycle's own JSONL. Prints exactly one of:
#
#   learned      — >=1 {"ev":"learned"} event exists anywhere in the log.
#   no_learning  — zero {"ev":"learned"} events AND >=1 {"ev":"no_learning"}
#                  event exists (every role that ran honestly declared it
#                  learned nothing durable).
#   absent       — neither event kind present (missing/unreadable log,
#                  truncated cycle, or a legacy log predating the
#                  ev:no_learning contract). Fail-SAFE: callers must treat
#                  `absent` the same as `learned` (spawn the curator) — a
#                  missing signal is never read as permission to skip.
#
# `learned` wins over `no_learning` whenever both are present (mixed cycle:
# some roles learned something, others didn't — there IS something to
# curate). Never raises; jq errors are swallowed (fail-open to `absent`,
# which is itself fail-SAFE at the caller).
curator_learning_signal_from_log() {
    local log_file="$1"
    [ -f "$log_file" ] || {
        printf 'absent'
        return 0
    }

    local has_learned has_no_learning
    has_learned=$(jq -e 'select(.ev == "learned")' "$log_file" >/dev/null 2>&1 && echo 1 || echo 0)
    has_no_learning=$(jq -e 'select(.ev == "no_learning")' "$log_file" >/dev/null 2>&1 && echo 1 || echo 0)

    if [ "$has_learned" = "1" ]; then
        printf 'learned'
    elif [ "$has_no_learning" = "1" ]; then
        printf 'no_learning'
    else
        printf 'absent'
    fi
}

# gate_timeout_for <command> — print timeout in seconds for a gate command.
# The timeout budget is based on substring matching, independent of gate mode:
#   make ci (with or without llm)  → present in combined → contributes 900
#   make llm (excluding validate)  → present alone        → 1500
#   both make ci and make llm      → combined             → 1800
#   anything else                  → 0
#
# The three named gates:
#   "make ci"              → 900
#   "make llm"             → 1500
#   "make ci && make llm"  → 1800
#   "make ci" (short)      → 900
#   "make llm-phoenix-validate" → 0
gate_timeout_for() {
    local cmd="$1"
    local has_llm=0
    local has_ci=0

    # Does command contain a standalone `make ci` (not ci-cover, not ci-skip, etc.)?
    # Match `make ci` only when followed by end-of-string, space, or non-alphanumeric/dash.
    if printf '%s' "$cmd" | grep -qE '\bmake[[:space:]]+ci([[:space:]]|$)'; then
        has_ci=1
    fi

    # Does command contain a real `make llm` target (llm, llm-phoenix) but NOT
    # llm-phoenix-validate-only (which is short)?
    # A command is "llm-bearing" if it has make llm, make llm-phoenix, or rebuild-seed-then
    # but only if it is NOT exclusively llm-phoenix-validate with nothing else.
    if printf '%s' "$cmd" | grep -qE '\bmake[[:space:]]+llm([[:space:]]|$)|\bmake[[:space:]]+llm-phoenix([[:space:]]|$)'; then
        # Exclude validate-only: has llm-phoenix-validate but NOT llm or llm-phoenix (standalone)
        if printf '%s' "$cmd" | grep -qE '\bmake[[:space:]]+llm-phoenix-validate\b' &&
            ! printf '%s' "$cmd" | grep -qE '\bmake[[:space:]]+llm([[:space:]]|$)|\bmake[[:space:]]+llm-phoenix([[:space:]]|$)'; then
            has_llm=0
        else
            has_llm=1
        fi
    fi

    if [ "$has_ci" -eq 1 ] && [ "$has_llm" -eq 1 ]; then
        printf '1800'
    elif [ "$has_ci" -eq 1 ]; then
        printf '900'
    elif [ "$has_llm" -eq 1 ]; then
        printf '1500'
    else
        printf '0'
    fi
}

# gate_mode_for <command> — print "short" or "long" for a command string.
gate_mode_for() {
    local cmd="$1"
    if printf '%s' "$cmd" | grep -qE '\bmake[[:space:]]+llm\b|rebuild-seed-then'; then
        # llm-phoenix-validate is short despite the "make llm" prefix.
        if printf '%s' "$cmd" | grep -qE '\bmake[[:space:]]+llm-phoenix-validate\b' &&
            ! printf '%s' "$cmd" | grep -qE '\bmake[[:space:]]+llm([[:space:]]|$)|\bmake[[:space:]]+llm-phoenix([[:space:]]|$)|rebuild-seed-then'; then
            printf 'short'
        else
            printf 'long'
        fi
    else
        printf 'short'
    fi
}

# gate_select_read_planner_gate <step_log_file> — read the planner's typed
# gate-SELECTION event ({"ev":"plan_gate","role":<planner*>,"command":<cmd>,
# "mode":"short"|"long","timeout":<seconds>}), written by
# `codegen-log append <role> --plan-gate @-`. Prints the command on the first
# line followed by __GATE_JSON_MODE=<mode> and __GATE_JSON_TIMEOUT=<timeout>
# lines (same output contract gate_select_decide already parses). Empty when
# the log is missing, unreadable, or carries no plan_gate event for a
# planner* role — caller falls through to its existing "no gate found" path.
# No prose fallback: a missing structured field blocks, it never re-parses
# `body` (session-log.md § the body is opaque, never re-parsed as structure).
gate_select_read_planner_gate() {
    local log_file="$1"
    [ -f "$log_file" ] || {
        printf ''
        return 0
    }

    local last_event
    last_event=$(jq -c 'select(.ev == "plan_gate" and (.role | startswith("planner")))' \
        "$log_file" 2>/dev/null | tail -n 1)
    [ -z "$last_event" ] && {
        printf ''
        return 0
    }

    local cmd mode timeout
    cmd=$(printf '%s' "$last_event" | jq -r '.command // empty' 2>/dev/null)
    mode=$(printf '%s' "$last_event" | jq -r '.mode // empty' 2>/dev/null)
    timeout=$(printf '%s' "$last_event" | jq -r '.timeout // empty' 2>/dev/null)

    [ -z "$cmd" ] && {
        printf ''
        return 0
    }

    printf '%s\n__GATE_JSON_MODE=%s\n__GATE_JSON_TIMEOUT=%s\n' "$cmd" "$mode" "${timeout:-0}"
}

# gate_select_decide <project_dir> [<step_log_file>]
# Prints "gate=<cmd>\nmode=<short|long>".
gate_select_decide() {
    local project_dir="$1"
    local step_log="${2:-}"

    # 1. Planner gate wins. Malformed selections can never reach the log —
    # codegen-log validates --plan-gate JSON shape at write time — so there
    # is no parse-error sentinel to propagate here anymore.
    if [ -n "$step_log" ] && [ -f "$step_log" ]; then
        local planner_out
        planner_out=$(gate_select_read_planner_gate "$step_log")

        if [ -n "$planner_out" ]; then
            # Extract command (first line), and optional JSON sideband fields
            local plan_gate json_mode json_timeout mode timeout
            plan_gate=$(printf '%s' "$planner_out" | sed -n '1p')
            json_mode=$(printf '%s' "$planner_out" | sed -n 's/^__GATE_JSON_MODE=//p' | head -n 1)
            json_timeout=$(printf '%s' "$planner_out" | sed -n 's/^__GATE_JSON_TIMEOUT=//p' | head -n 1)

            if [ -n "$json_mode" ]; then
                mode="$json_mode"
                timeout="${json_timeout:-0}"
            else
                mode=$(gate_mode_for "$plan_gate")
                timeout=$(gate_timeout_for "$plan_gate")
            fi
            printf 'gate=%s\nmode=%s\ntimeout=%s\n' "$plan_gate" "$mode" "$timeout"
            return 0
        fi
    fi

    # 2. Per-app config: a single required GATE_COMMAND variable.
    local config="$project_dir/.claude/gate-config.sh"
    if [ ! -f "$config" ]; then
        printf '__GATE_UNRESOLVED__:no planner gate and no %s\n' "$config"
        return 0
    fi

    GATE_COMMAND=""
    # shellcheck disable=SC1090
    source "$config"

    if [ -z "$GATE_COMMAND" ]; then
        printf '__GATE_UNRESOLVED__:%s present but GATE_COMMAND is empty\n' "$config"
        return 0
    fi

    local mode timeout
    mode=$(gate_mode_for "$GATE_COMMAND")
    timeout=$(gate_timeout_for "$GATE_COMMAND")
    printf 'gate=%s\nmode=%s\ntimeout=%s\n' "$GATE_COMMAND" "$mode" "$timeout"
}
