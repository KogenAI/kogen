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
#   1. The active step log's `## Plan` section first `**Gate**:` (or `Gate:`) line.
#      If present, planner wins — gate = that string, mode chosen from the
#      command itself (see `gate_mode_for`).
#   2. Otherwise, project-local config at `<project_dir>/.claude/gate-config.sh`,
#      sourced for its variables. The config drives a project-specific tree
#      based on `git diff --name-only origin/main..HEAD`.
#   3. Otherwise (no config), fall back to `mode=short gate="make test"`.
#
# Project config contract (`<project_dir>/.claude/gate-config.sh`):
#
#   GATE_SHORT_DEFAULT       — gate when none of the path regexes match and
#                              this is NOT the final step (e.g. "make ci")
#   GATE_SHORT_FINAL         — gate when none match and step is final
#                              (e.g. "make ci")
#   GATE_LLM                 — gate when LLM_PATHS_REGEX matches
#                              (e.g. "make ci && make llm")
#   GATE_LLM_AND_PHOENIX     — gate when both LLM and PHOENIX match
#                              (e.g. "make ci && make llm && make llm-phoenix")
#   GATE_PHOENIX             — gate when only PHOENIX matches and seed is healthy
#                              (e.g. "make llm-phoenix")
#   GATE_PHOENIX_VALIDATE_THEN — gate when PHOENIX matches and validated marker
#                              is missing (e.g. "make llm-phoenix-validate && make llm-phoenix")
#   GATE_PHOENIX_REBUILD_THEN  — gate when PHOENIX matches and seed.bundle/seed.sql
#                              are missing (e.g. "COMBOBULATE_VE_GATE=rebuild-seed-then make llm-phoenix")
#   LLM_PATHS_REGEX          — extended regex matched against changed paths
#   PHOENIX_PATHS_REGEX      — extended regex matched against changed paths
#   SEED_BUNDLE_PATH         — absolute path to seed.bundle (existence check)
#   SEED_SQL_PATH            — absolute path to seed.sql (existence check)
#   SEED_VALIDATED_PATH      — absolute path to validated marker
#   GATE_FINAL_STEP_DETECTOR — bash command (string) that exits 0 if this step
#                              is the final step in the multi-step session.
#                              Defaults to "true" (always final → use SHORT_FINAL).
#
# Mode selection from gate string (`gate_mode_for`):
#   contains "make llm" or "rebuild-seed-then" → long
#   anything else                              → short

set -u

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

# gate_select_read_planner_gate <step_log_file> — print the planner's
# `**Gate**:` value (without the `**Gate**:` prefix and surrounding markdown),
# or empty if absent. Reads only the `## Plan` section.
gate_select_read_planner_gate() {
    local log_file="$1"
    [ -f "$log_file" ] || {
        printf ''
        return 0
    }

    awk '
        /^## Plan[[:space:]]*$/ { in_plan = 1; next }
        in_plan && /^## / && !/^## Plan/ { exit }
        in_plan {
            line = $0
            # Match **Gate**: or Gate:
            if (match(line, /^\*\*Gate\*\*:[[:space:]]*/) || match(line, /^Gate:[[:space:]]*/)) {
                rest = substr(line, RSTART + RLENGTH)
                # Strip leading/trailing backticks and whitespace
                gsub(/^`+|`+$/, "", rest)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
                # If backticks present, truncate at first backtick (closing fence)
                if (match(rest, /`/)) {
                    rest = substr(rest, 1, RSTART - 1)
                    gsub(/[[:space:]]+$/, "", rest)
                }
                # If no backticks, truncate at prose separators: ` (`, ` —`, ` - `
                else {
                    if (match(rest, / *\(/))     { rest = substr(rest, 1, RSTART - 1) }
                    else if (match(rest, / *—/)) { rest = substr(rest, 1, RSTART - 1) }
                    else if (match(rest, / +-+ /)) { rest = substr(rest, 1, RSTART - 1) }
                    gsub(/[[:space:]]+$/, "", rest)
                }
                if (length(rest) > 0) { print rest; exit }
            }
        }
    ' "$log_file"
}

# gate_select_decide <project_dir> [<step_log_file>]
# Prints "gate=<cmd>\nmode=<short|long>".
gate_select_decide() {
    local project_dir="$1"
    local step_log="${2:-}"

    # 1. Planner gate wins.
    if [ -n "$step_log" ] && [ -f "$step_log" ]; then
        local plan_gate
        plan_gate=$(gate_select_read_planner_gate "$step_log")
        if [ -n "$plan_gate" ]; then
            local mode timeout
            mode=$(gate_mode_for "$plan_gate")
            timeout=$(gate_timeout_for "$plan_gate")
            printf 'gate=%s\nmode=%s\ntimeout=%s\n' "$plan_gate" "$mode" "$timeout"
            return 0
        fi
    fi

    # 2. Project config drives the tree.
    local config="$project_dir/.claude/gate-config.sh"
    if [ ! -f "$config" ]; then
        # 3. No config — generic fallback.
        printf 'gate=make test\nmode=short\ntimeout=0\n'
        return 0
    fi

    # Source config in a subshell-safe manner.
    # shellcheck disable=SC1090
    GATE_SHORT_DEFAULT=""
    GATE_SHORT_FINAL=""
    GATE_LLM=""
    GATE_LLM_AND_PHOENIX=""
    GATE_PHOENIX=""
    GATE_PHOENIX_VALIDATE_THEN=""
    GATE_PHOENIX_REBUILD_THEN=""
    LLM_PATHS_REGEX=""
    PHOENIX_PATHS_REGEX=""
    SEED_BUNDLE_PATH=""
    SEED_SQL_PATH=""
    SEED_VALIDATED_PATH=""
    GATE_FINAL_STEP_DETECTOR="true"
    # shellcheck disable=SC1090
    source "$config"

    # Compute changed paths: committed-vs-origin/main + working-tree-vs-HEAD +
    # untracked files. Untracked files matter because new modules introduced in
    # the current step won't appear in any `git diff` output.
    local diff_out=""
    if (cd "$project_dir" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
        local committed wt untracked
        committed=$(cd "$project_dir" && git diff --name-only origin/main...HEAD 2>/dev/null)
        wt=$(cd "$project_dir" && git diff --name-only HEAD 2>/dev/null)
        untracked=$(cd "$project_dir" && git ls-files --others --exclude-standard 2>/dev/null)
        diff_out=$(printf '%s\n%s\n%s\n' "$committed" "$wt" "$untracked" | grep -v '^$' | sort -u)
    fi

    local llm_match=0
    local phx_match=0
    if [ -n "$LLM_PATHS_REGEX" ] && [ -n "$diff_out" ] &&
        printf '%s' "$diff_out" | grep -qE "$LLM_PATHS_REGEX"; then
        llm_match=1
    fi
    if [ -n "$PHOENIX_PATHS_REGEX" ] && [ -n "$diff_out" ] &&
        printf '%s' "$diff_out" | grep -qE "$PHOENIX_PATHS_REGEX"; then
        phx_match=1
    fi

    local gate=""
    if [ "$llm_match" -eq 1 ] && [ "$phx_match" -eq 1 ]; then
        gate="$GATE_LLM_AND_PHOENIX"
    elif [ "$llm_match" -eq 1 ]; then
        gate="$GATE_LLM"
    elif [ "$phx_match" -eq 1 ]; then
        # Seed health gating.
        if [ -n "$SEED_BUNDLE_PATH" ] && [ ! -f "$SEED_BUNDLE_PATH" ]; then
            gate="$GATE_PHOENIX_REBUILD_THEN"
        elif [ -n "$SEED_SQL_PATH" ] && [ ! -f "$SEED_SQL_PATH" ]; then
            gate="$GATE_PHOENIX_REBUILD_THEN"
        elif [ -n "$SEED_VALIDATED_PATH" ] && [ ! -f "$SEED_VALIDATED_PATH" ]; then
            gate="$GATE_PHOENIX_VALIDATE_THEN"
        else
            gate="$GATE_PHOENIX"
        fi
    else
        # No matches — final-step detection.
        # Wrap eval in a subshell so that `exit 0`/`exit 1` inside the
        # detector script terminates the subshell, not the parent function.
        if (eval "$GATE_FINAL_STEP_DETECTOR") >/dev/null 2>&1; then
            gate="$GATE_SHORT_FINAL"
        else
            gate="$GATE_SHORT_DEFAULT"
        fi
    fi

    if [ -z "$gate" ]; then
        gate="make test"
    fi

    local mode timeout
    mode=$(gate_mode_for "$gate")
    timeout=$(gate_timeout_for "$gate")
    printf 'gate=%s\nmode=%s\ntimeout=%s\n' "$gate" "$mode" "$timeout"
}
