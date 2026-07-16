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
#   1. The active step log's `## Plan` section first `**Gate**:` (or `Gate:`)
#      line, or its ```gate-json block. If present, planner wins — gate = that
#      string, mode/timeout from the JSON sideband or `gate_mode_for`/`gate_timeout_for`.
#   2. Otherwise, per-app config `<project_dir>/.claude/gate-config.sh`, sourced
#      for a single required variable GATE_COMMAND. If GATE_COMMAND is non-empty,
#      gate = GATE_COMMAND (mode/timeout via gate_mode_for/gate_timeout_for).
#   3. Otherwise (no planner gate AND no GATE_COMMAND): FAIL LOUD. Print
#      `__GATE_UNRESOLVED__:<reason>` to stdout and return 0. There is NO
#      stack-guessing fallback and NO default gate — an unresolved gate is a
#      real misconfiguration the caller must surface (block / raise), never
#      silently skip.
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

# gate_select_read_planner_json <step_log_file>
# Extracts a ```gate-json block from the planner's role body (decoded from
# the JSONL cycle log via planner_body_from_log — the body text is treated as
# though it were still a "## Plan" section, since that's the prose shape
# planners still write inside the opaque body string).
# On success: prints gate command to stdout and sets the env vars
#   __GATE_JSON_MODE and __GATE_JSON_TIMEOUT (caller reads them after).
# On malformed/invalid JSON block: prints "__GATE_PARSE_ERROR__:<reason>" and returns 0.
# On no block found: prints nothing and returns 0 (caller falls through).
# Uses jq for validation.
gate_select_read_planner_json() {
    local log_file="$1"
    [ -f "$log_file" ] || {
        printf ''
        return 0
    }

    local body
    body=$(planner_body_from_log "$log_file")
    [ -z "$body" ] && {
        printf ''
        return 0
    }

    # Extract the gate-json block that immediately follows a **Gate**: line.
    # This avoids picking up gate-json blocks that appear as FORMAT EXAMPLES in
    # the plan body. The body IS the planner's role prose (the "## Plan"
    # section content, or the whole body if no such sub-heading is present) —
    # scan the entire body directly; a "## <other> Section" heading inside a
    # planner's own body would only appear as a stray, non-authoritative
    # string (planner bodies do not carry OTHER roles' sections under
    # per-event JSONL storage), so no early-exit boundary is needed.
    local json_block
    json_block=$(printf '%s' "$body" | awk '
        /^\*\*Gate\*\*:/ { after_gate = 1; next }
        after_gate && /^[[:space:]]*$/ { next }
        after_gate && /^```gate-json[[:space:]]*$/ { in_block = 1; after_gate = 0; next }
        after_gate { after_gate = 0 }
        in_block && /^```[[:space:]]*$/ { in_block = 0; exit }
        in_block { print }
    ' 2>/dev/null)

    # No block found — fall through to prose parser
    [ -z "$json_block" ] && {
        printf ''
        return 0
    }

    # Validate JSON with jq
    if ! printf '%s' "$json_block" | jq -e . >/dev/null 2>&1; then
        printf '__GATE_PARSE_ERROR__:gate-json block is not valid JSON'
        return 0
    fi

    # Extract required fields
    local cmd mode timeout
    cmd=$(printf '%s' "$json_block" | jq -r '.command // empty' 2>/dev/null)
    mode=$(printf '%s' "$json_block" | jq -r '.mode // empty' 2>/dev/null)
    timeout=$(printf '%s' "$json_block" | jq -r '.timeout // empty' 2>/dev/null)

    if [ -z "$cmd" ]; then
        printf '__GATE_PARSE_ERROR__:gate-json block missing required field "command"'
        return 0
    fi
    if [ -z "$mode" ]; then
        printf '__GATE_PARSE_ERROR__:gate-json block missing required field "mode"'
        return 0
    fi
    if [ -z "$timeout" ]; then
        printf '__GATE_PARSE_ERROR__:gate-json block missing required field "timeout"'
        return 0
    fi

    # Validate mode
    case "$mode" in
    short | long) ;;
    *)
        printf '__GATE_PARSE_ERROR__:gate-json block invalid mode "%s" (must be short or long)' "$mode"
        return 0
        ;;
    esac

    # Output: command on first line, then __GATE_JSON_MODE=<mode> and
    # __GATE_JSON_TIMEOUT=<timeout> on subsequent lines. Caller parses with sed.
    printf '%s\n__GATE_JSON_MODE=%s\n__GATE_JSON_TIMEOUT=%s\n' "$cmd" "$mode" "$timeout"
}

# gate_select_read_planner_gate <step_log_file> — print the planner's
# `**Gate**:` value (without the `**Gate**:` prefix and surrounding markdown),
# or empty if absent. Reads the planner role body decoded from the JSONL
# cycle log (planner_body_from_log) — the body IS the "## Plan" prose.
#
# NEW: tries gate_select_read_planner_json first. On valid JSON block, returns
# the command on the first line followed by __GATE_JSON_MODE=<mode> and
# __GATE_JSON_TIMEOUT=<timeout> lines (for gate_select_decide to parse).
# On parse error, returns the __GATE_PARSE_ERROR__ sentinel. Only falls through
# to the awk prose parser when no JSON block is found (backward compat).
gate_select_read_planner_gate() {
    local log_file="$1"
    [ -f "$log_file" ] || {
        printf ''
        return 0
    }

    # Try JSON path first
    local json_result
    json_result=$(gate_select_read_planner_json "$log_file")

    # Parse error — propagate sentinel directly
    case "$json_result" in
    __GATE_PARSE_ERROR__:*)
        printf '%s' "$json_result"
        return 0
        ;;
    esac

    # Valid JSON result (non-empty, not error) — includes mode/timeout lines
    if [ -n "$json_result" ]; then
        printf '%s' "$json_result"
        return 0
    fi

    # No JSON block — fall through to existing prose awk parser (backward
    # compat), scanning the decoded planner body directly.
    local body
    body=$(planner_body_from_log "$log_file")
    [ -z "$body" ] && {
        printf ''
        return 0
    }
    printf '%s' "$body" | awk '
        {
            line = $0
            # Match **Gate**: or Gate:
            if (match(line, /^\*\*Gate\*\*:[[:space:]]*/) || match(line, /^Gate:[[:space:]]*/)) {
                rest = substr(line, RSTART + RLENGTH)
                # Decide backtick-wrapping on the RAW rest BEFORE stripping.
                gsub(/^[[:space:]]+/, "", rest)
                if (substr(rest, 1, 1) == "`") {
                    # Wrapped gate: take content between the first opening and
                    # next closing backtick verbatim. No prose truncation.
                    inner = substr(rest, 2)
                    if (match(inner, /`/)) { inner = substr(inner, 1, RSTART - 1) }
                    rest = inner
                    gsub(/[[:space:]]+$/, "", rest)
                } else {
                    # Bare gate: trim, then truncate at prose separators.
                    gsub(/[[:space:]]+$/, "", rest)
                    if (match(rest, / *\(/))       { rest = substr(rest, 1, RSTART - 1) }
                    else if (match(rest, / *—/))   { rest = substr(rest, 1, RSTART - 1) }
                    else if (match(rest, / +-+ /)) { rest = substr(rest, 1, RSTART - 1) }
                    gsub(/[[:space:]]+$/, "", rest)
                }
                if (length(rest) > 0) { print rest; exit }
            }
        }
    '
}

# gate_select_decide <project_dir> [<step_log_file>]
# Prints "gate=<cmd>\nmode=<short|long>".
gate_select_decide() {
    local project_dir="$1"
    local step_log="${2:-}"

    # 1. Planner gate wins.
    if [ -n "$step_log" ] && [ -f "$step_log" ]; then
        local planner_out
        planner_out=$(gate_select_read_planner_gate "$step_log")

        # Propagate parse error sentinel directly — callers (stop-verify) handle it
        case "$planner_out" in
        __GATE_PARSE_ERROR__:*)
            printf '%s' "$planner_out"
            return 0
            ;;
        esac

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
