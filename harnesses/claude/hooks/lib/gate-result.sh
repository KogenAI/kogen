#!/usr/bin/env bash
# gate-result.sh — Shared helper for writing and reading structured gate result files.
#
# Sourceable. After sourcing, call:
#
#   write_gate_result <gate> <mode> <base_sha> <diff_files_count> \
#       <runner_found> <exit_code> <execution_evidence> <expected_segments> \
#       <render_verdict> <classification> <started> <ended> \
#       <session_id> <log> <project_dir> [<witness>] [<graded_tree_sha>]
#
# Writes codegen/gate-pending/gate-result.json under <project_dir>.
# Verdict derivation is fully deterministic — see table below.
#
#   gate_result_verdict <project_dir> — reads verdict field from result file.
#       Prints verdict string (clear|failed|inconclusive) or "" if absent.
#
#   gate_result_graded_tree_sha <project_dir> — reads graded_tree_sha field.
#       Prints the sha or "" if absent. Binds this verdict to the exact
#       working-tree content it graded (base_sha alone only pins HEAD, not
#       content — a post-gate revert leaves base_sha unchanged).
#
# Verdict derivation table:
#   runner_found=false                            → failed  / FAILED ❌
#   exit ∈ {126,127}                              → failed  / FAILED ❌
#   exit≠0, classification ∈ {seed-missing,pool-exhaustion} → inconclusive / INCONCLUSIVE ⚠️
#   exit≠0 (other)                                → failed  / FAILED ❌
#   timeout (exit="timeout")                      → inconclusive / INCONCLUSIVE ⚠️
#   exit=0, execution_evidence < expected_segments→ failed  / FAILED ❌  (no-op gate)
#   exit=0, render_verdict=FAIL:*                 → failed  / FAILED ❌
#   exit=0, render_verdict=INCONCLUSIVE:*         → inconclusive / INCONCLUSIVE ⚠️
#   exit=0, evidence ok, render ∈ {PASS,""}       → clear   / ALL CLEAR ✅

set -u

# _derive_verdict <runner_found> <exit_code> <execution_evidence> <expected_segments>
#                 <render_verdict> <classification>
# Prints two lines: verdict= and verdict_marker=
_derive_verdict() {
    local runner_found="$1"
    local exit_code="$2"
    local execution_evidence="$3"
    local expected_segments="$4"
    local render_verdict="$5"
    local classification="$6"

    # runner not found
    if [ "$runner_found" = "false" ]; then
        printf 'verdict=failed\nverdict_marker=FAILED ❌\n'
        return 0
    fi

    # timeout
    if [ "$exit_code" = "timeout" ]; then
        printf 'verdict=inconclusive\nverdict_marker=INCONCLUSIVE ⚠️\n'
        return 0
    fi

    # exit 126 or 127 → command not found/executable
    if [ "$exit_code" = "126" ] || [ "$exit_code" = "127" ]; then
        printf 'verdict=failed\nverdict_marker=FAILED ❌\n'
        return 0
    fi

    # non-zero exit
    if [ "$exit_code" != "0" ]; then
        # environmental classifications → inconclusive
        case "$classification" in
        seed-missing* | pool-exhaustion*)
            printf 'verdict=inconclusive\nverdict_marker=INCONCLUSIVE ⚠️\n'
            return 0
            ;;
        esac
        printf 'verdict=failed\nverdict_marker=FAILED ❌\n'
        return 0
    fi

    # exit=0 branch
    # execution evidence check (no-op gate detection)
    if [ "$expected_segments" -gt 0 ] && [ "$execution_evidence" -lt "$expected_segments" ]; then
        printf 'verdict=failed\nverdict_marker=FAILED ❌\n'
        return 0
    fi

    # render verdict check
    case "$render_verdict" in
    FAIL:*)
        printf 'verdict=failed\nverdict_marker=FAILED ❌\n'
        return 0
        ;;
    INCONCLUSIVE:*)
        printf 'verdict=inconclusive\nverdict_marker=INCONCLUSIVE ⚠️\n'
        return 0
        ;;
    esac

    # All checks passed
    printf 'verdict=clear\nverdict_marker=ALL CLEAR ✅\n'
}

# extract_witness <log_path>
# Best-effort: prints "file:line — <verbatim matched line>" for the first
# parseable failure location found in the gate log (ExUnit / credo / dialyzer).
# Fall-open-empty contract: prints "" and returns 0 when log absent or no match.
# NEVER errors — a missing witness must never break the gate.
extract_witness() {
    local log_path="${1:-}"
    [ -n "$log_path" ] && [ -f "$log_path" ] || {
        printf ''
        return 0
    }
    local line=""
    # ExUnit failure stacktrace location: "  test/foo_test.exs:42: ..." or
    # "  (myapp 1.0) lib/foo.ex:12: ..." → capture path:line.
    line=$(grep -oE '[A-Za-z0-9_./-]+\.(exs?|heex):[0-9]+' "$log_path" 2>/dev/null | head -n 1 || true)
    if [ -z "$line" ]; then
        # credo / dialyzer location: "lib/foo.ex:12:7:" (col optional).
        line=$(grep -oE '[A-Za-z0-9_./-]+\.exs?:[0-9]+(:[0-9]+)?' "$log_path" 2>/dev/null | head -n 1 || true)
    fi
    [ -n "$line" ] || {
        printf ''
        return 0
    }
    # Pull the first full log line containing that location for verbatim context.
    local verbatim
    verbatim=$(grep -m1 -F "$line" "$log_path" 2>/dev/null | sed 's/^[[:space:]]*//' || true)
    if [ -n "$verbatim" ]; then
        printf '%s — %s' "$line" "$verbatim"
    else
        printf '%s' "$line"
    fi
    return 0
}

# write_gate_result <gate> <mode> <base_sha> <diff_files_count>
#     <runner_found> <exit_code> <execution_evidence> <expected_segments>
#     <render_verdict> <classification> <started> <ended>
#     <session_id> <log> <project_dir> [<witness>] [<graded_tree_sha>]
write_gate_result() {
    local gate="$1"
    local mode="$2"
    local base_sha="$3"
    local diff_files_count="$4"
    local runner_found="$5"
    local exit_code="$6"
    local execution_evidence="$7"
    local expected_segments="$8"
    local render_verdict="$9"
    local classification="${10}"
    local started="${11}"
    local ended="${12}"
    local session_id="${13}"
    local log="${14}"
    local project_dir="${15}"
    local witness="${16:-}"
    local graded_tree_sha="${17:-}"

    # Derive verdict
    local verdict_out
    verdict_out=$(_derive_verdict "$runner_found" "$exit_code" \
        "$execution_evidence" "$expected_segments" "$render_verdict" "$classification")
    local verdict verdict_marker
    verdict=$(printf '%s' "$verdict_out" | sed -n 's/^verdict=//p' | head -n 1)
    verdict_marker=$(printf '%s' "$verdict_out" | sed -n 's/^verdict_marker=//p' | head -n 1)

    local result_dir="$project_dir/codegen/gate-pending"
    mkdir -p "$result_dir"
    local result_file="$result_dir/gate-result.json"

    # Numeric fields need special handling for jq
    local exit_num="$exit_code"
    local exit_arg_type="--arg"
    if [ "$exit_code" = "timeout" ] || [ "$exit_code" = "" ]; then
        exit_arg_type="--arg"
        exit_num="$exit_code"
    else
        # Valid integer — pass as number
        exit_arg_type="--argjson"
    fi

    # diff_files_count and evidence/segments always numeric
    jq -n \
        --arg gate "$gate" \
        --arg mode "$mode" \
        --arg base_sha "$base_sha" \
        --argjson diff_files_count "${diff_files_count:-0}" \
        --argjson runner_found "$([ "$runner_found" = "true" ] && echo true || echo false)" \
        $exit_arg_type exit "${exit_num:-0}" \
        --argjson execution_evidence "${execution_evidence:-0}" \
        --argjson expected_segments "${expected_segments:-0}" \
        --arg render_verdict "$render_verdict" \
        --arg verdict "$verdict" \
        --arg verdict_marker "$verdict_marker" \
        --arg classification "$classification" \
        --arg started "$started" \
        --arg ended "$ended" \
        --arg session_id "$session_id" \
        --arg log "$log" \
        --arg witness "$witness" \
        --arg graded_tree_sha "$graded_tree_sha" \
        '{
            gate: $gate,
            mode: $mode,
            base_sha: $base_sha,
            diff_files_count: $diff_files_count,
            runner_found: $runner_found,
            exit: $exit,
            execution_evidence: $execution_evidence,
            expected_segments: $expected_segments,
            render_verdict: $render_verdict,
            verdict: $verdict,
            verdict_marker: $verdict_marker,
            classification: $classification,
            started: $started,
            ended: $ended,
            session_id: $session_id,
            log: $log,
            witness: $witness,
            graded_tree_sha: $graded_tree_sha
        }' >"$result_file"

    # Durable codegen-local verdict history (no overwrite, append-only).
    # Only when project_dir is the codegen repo (sentinel present). || true:
    # never block a gate on observability.
    if [ -f "$project_dir/shared/enforcement/registry.yaml" ]; then
        local history_file="$project_dir/codegen/logging/gate-verdicts.jsonl"
        mkdir -p "$project_dir/codegen/logging" 2>/dev/null || true
        jq -c '.' "$result_file" >>"$history_file" 2>/dev/null || true
    fi
}

# gate_result_verdict <project_dir>
# Reads verdict field from gate-result.json. Prints verdict or "" if absent.
gate_result_verdict() {
    local project_dir="$1"
    local result_file="$project_dir/codegen/gate-pending/gate-result.json"
    [ -f "$result_file" ] || {
        printf ''
        return 0
    }
    jq -r '.verdict // ""' "$result_file" 2>/dev/null || printf ''
}

# gate_result_base_sha <project_dir>
# Reads base_sha field from gate-result.json. Prints base_sha or "" if absent.
gate_result_base_sha() {
    local project_dir="$1"
    local result_file="$project_dir/codegen/gate-pending/gate-result.json"
    [ -f "$result_file" ] || {
        printf ''
        return 0
    }
    jq -r '.base_sha // ""' "$result_file" 2>/dev/null || printf ''
}

# gate_result_graded_tree_sha <project_dir>
# Reads graded_tree_sha field from gate-result.json. Prints the sha or ""
# if absent (legacy record predating this field, or non-git gate run).
gate_result_graded_tree_sha() {
    local project_dir="$1"
    local result_file="$project_dir/codegen/gate-pending/gate-result.json"
    [ -f "$result_file" ] || {
        printf ''
        return 0
    }
    jq -r '.graded_tree_sha // ""' "$result_file" 2>/dev/null || printf ''
}
