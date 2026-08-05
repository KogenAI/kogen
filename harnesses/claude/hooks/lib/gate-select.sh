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
# Input — a single source, the per-app config:
#   1. `<project_dir>/.claude/gate-config.sh`, sourced for one required
#      variable GATE_COMMAND plus two optional ones, GATE_MODE and
#      GATE_TIMEOUT. If GATE_COMMAND is non-empty, gate = GATE_COMMAND;
#      mode/timeout come from GATE_MODE/GATE_TIMEOUT when the config sets
#      them, else from gate_mode_for/gate_timeout_for.
#   2. Otherwise (no config file, or no GATE_COMMAND): FAIL LOUD. Print
#      `__GATE_UNRESOLVED__:<reason>` to stdout and return 0. There is NO
#      stack-guessing fallback and NO default gate — an unresolved gate is a
#      real misconfiguration the caller must surface (block / raise), never
#      silently skip.
#
# There is no per-cycle gate override: the gate is a per-PROJECT operator
# declaration, read verbatim from the config, never inferred from any role's
# output and never re-parsed out of free-form body prose. See
# shared/rules/_core/session-log.md § the body is opaque, never re-parsed as
# structure.
#
# Per-app config contract (`<project_dir>/.claude/gate-config.sh`):
#   GATE_COMMAND — REQUIRED. The exact gate command for this app (e.g. "make ci"
#                  for a Phoenix/static downstream app, "make test" for codegen
#                  itself).
#   GATE_MODE    — OPTIONAL. "short" or "long". Unset/empty → derived from
#                  GATE_COMMAND by gate_mode_for. Any other value is a
#                  misconfiguration and yields __GATE_UNRESOLVED__ — never a
#                  silent fall-back to the heuristic, which would hide the typo.
#   GATE_TIMEOUT — OPTIONAL. Non-negative integer, seconds. Unset/empty →
#                  derived from GATE_COMMAND by gate_timeout_for. Non-numeric is
#                  a misconfiguration and yields __GATE_UNRESOLVED__.
#
# Why the two optional overrides exist: the gate_mode_for/gate_timeout_for
# heuristics only recognise `make ci`, `make llm` and `rebuild-seed-then`. Any
# other gate command — codegen's own "make test", for one — derives
# mode=short/timeout=0, i.e. no declared budget. The consumer
# (LoopGate.run_with_deadline/4) floors a zero to its own 900s default, so this
# is not a hang; but a project whose real budget is neither 0 nor 900 has no way
# to say so from the command string alone. These two variables are that way:
# per-PROJECT, set by the operator, read verbatim, never re-derived.
#
# Mode selection from gate string (`gate_mode_for`, used only when GATE_MODE is
# unset):
#   contains "make llm" or "rebuild-seed-then" → long
#   anything else                              → short

set -u

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

# gate_select_decide <project_dir>
# Prints "gate=<cmd>\nmode=<short|long>\ntimeout=<seconds>".
gate_select_decide() {
    local project_dir="$1"

    # 1. Per-app config: a single required GATE_COMMAND variable. This is the
    # only resolver — there is no per-cycle override tier above it.
    local config="$project_dir/.claude/gate-config.sh"
    if [ ! -f "$config" ]; then
        printf '__GATE_UNRESOLVED__:no %s\n' "$config"
        return 0
    fi

    # Pre-clear all three before sourcing so a stale value inherited from the
    # caller's environment can never masquerade as a config declaration.
    GATE_COMMAND=""
    GATE_MODE=""
    GATE_TIMEOUT=""
    # shellcheck disable=SC1090
    source "$config"

    if [ -z "$GATE_COMMAND" ]; then
        printf '__GATE_UNRESOLVED__:%s present but GATE_COMMAND is empty\n' "$config"
        return 0
    fi

    # 1a. Optional per-project mode/timeout overrides. Set → authoritative,
    # taken verbatim, never re-derived from the command string. Unset/empty →
    # the gate_mode_for/gate_timeout_for heuristics, unchanged. A value that is
    # set but malformed FAILS LOUD rather than falling back — a silent fallback
    # would turn `GATE_MODE=fast` into a working config that ignores the
    # operator, and a non-numeric GATE_TIMEOUT would reach
    # LoopGate.decide_gate/1's String.to_integer as an ArgumentError anyway.
    local mode timeout
    if [ -n "$GATE_MODE" ]; then
        case "$GATE_MODE" in
        short | long)
            mode="$GATE_MODE"
            ;;
        *)
            printf '__GATE_UNRESOLVED__:%s sets GATE_MODE=%s (expected short or long)\n' "$config" "$GATE_MODE"
            return 0
            ;;
        esac
    else
        mode=$(gate_mode_for "$GATE_COMMAND")
    fi

    if [ -n "$GATE_TIMEOUT" ]; then
        case "$GATE_TIMEOUT" in
        *[!0-9]*)
            printf '__GATE_UNRESOLVED__:%s sets GATE_TIMEOUT=%s (expected a non-negative integer of seconds)\n' "$config" "$GATE_TIMEOUT"
            return 0
            ;;
        *)
            timeout="$GATE_TIMEOUT"
            ;;
        esac
    else
        timeout=$(gate_timeout_for "$GATE_COMMAND")
    fi

    printf 'gate=%s\nmode=%s\ntimeout=%s\n' "$GATE_COMMAND" "$mode" "$timeout"
}
