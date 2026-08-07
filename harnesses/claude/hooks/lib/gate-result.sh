#!/usr/bin/env bash
# gate-result.sh — Shared helper for writing and reading structured gate result files.
#
# Sourceable. After sourcing, call:
#
#   write_gate_result <gate> <mode> <base_sha> <diff_files_count> \
#       <runner_found> <exit_code> <execution_evidence> <expected_segments> \
#       <render_verdict> <classification> <started> <ended> \
#       <session_id> <log> <project_dir> [<witness>] [<graded_tree_sha>] \
#       [<cycle_id>]
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
    # ExUnit block anchor: find the first "  N) test ..." headline, require a
    # bare file:line on the very next non-blank line (this is the false-positive
    # guard rejecting non-ExUnit numbered lists), then prefer the block's
    # "stacktrace:" first frame over the n+1 definition line — the definition
    # line misleads on setup-raise (points at a test that never ran) and on
    # doctests (names the wrong file). Falls through to the legacy path below
    # when the anchor or the n+1 location is absent.
    local exunit_witness
    exunit_witness=$(awk '
        function emit(loc, headline, cause,    out) {
            out = loc " — " headline
            if (cause != "") out = out ": " cause
            print out
            emitted = 1
            exit
        }
        /^[[:space:]]*[0-9]+\)[[:space:]]/ {
            headline = $0
            sub(/^[[:space:]]+/, "", headline)
            sub(/[[:space:]]+$/, "", headline)
            state = 1
            next
        }
        state == 1 {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line !~ /^[A-Za-z0-9_.\/-]+\.(exs?|heex):[0-9]+$/) {
                state = 0
                next
            }
            def_loc = line
            state = 2
            next
        }
        state == 2 {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "") { emit(def_loc, headline, ""); }
            cause = line
            state = 3
            next
        }
        state == 3 && /^[[:space:]]*stacktrace:[[:space:]]*$/ {
            state = 4
            next
        }
        state == 4 {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (match(line, /^[A-Za-z0-9_.\/-]+\.(exs?|heex):[0-9]+/)) {
                stack_loc = substr(line, RSTART, RLENGTH)
                emit(stack_loc, headline, cause)
            }
            state = 0
            next
        }
        END {
            if (!emitted && state >= 2 && def_loc != "") emit(def_loc, headline, cause)
        }
    ' "$log_path" 2>/dev/null || true)
    if [ -n "$exunit_witness" ]; then
        printf '%s' "$exunit_witness"
        return 0
    fi
    # ExUnit failure stacktrace location: "  test/foo_test.exs:42: ..." or
    # "  (myapp 1.0) lib/foo.ex:12: ..." → capture path:line.
    line=$(grep -oE '[A-Za-z0-9_./-]+\.(exs?|heex):[0-9]+' "$log_path" 2>/dev/null | head -n 1 || true)
    if [ -z "$line" ]; then
        # credo / dialyzer location: "lib/foo.ex:12:7:" (col optional).
        line=$(grep -oE '[A-Za-z0-9_./-]+\.exs?:[0-9]+(:[0-9]+)?' "$log_path" 2>/dev/null | head -n 1 || true)
    fi
    if [ -z "$line" ]; then
        # Doc-shaped gate failure (e.g. context-index-parity): names a
        # context/*.md or PROJECT_CONTEXT.md file with NO line number by
        # construction — a doc has no compiler/test-runner location to
        # report. Without this branch the witness is empty and
        # resolve_gate_owner/2 falls back to the developer, who
        # subagent-read-discipline then denies the Read on that exact path.
        # No `\b` word-boundary: a GNU-grep extension with no guaranteed
        # BSD ERE support (required_platforms: [darwin, linux]); the
        # Elixir consumer's own \b-anchored @curator_owned_signatures
        # re-applies the boundary on its side.
        line=$(grep -oE 'context/[A-Za-z0-9_-]+\.md|PROJECT_CONTEXT\.md' "$log_path" 2>/dev/null | head -n 1 || true)
        [ -n "$line" ] && {
            printf '%s' "$line"
            return 0
        }
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
#     <session_id> <log> <project_dir> [<witness>] [<graded_tree_sha>] [<cycle_id>]
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
    # cycle_id binds this verdict to the BUILD that paid for it. Without it
    # gate-verdicts.jsonl was unjoinable: `session_id` holds a role name, so
    # two verdicts from different builds are indistinguishable, and
    # "how much gate time did this build spend" had no answer. Optional and
    # defaulted to "" so every existing caller (and every downstream app,
    # which has no loop and no cycle) keeps working unchanged.
    local cycle_id="${18:-}"

    # Derive verdict
    local verdict_out
    verdict_out=$(_derive_verdict "$runner_found" "$exit_code" \
        "$execution_evidence" "$expected_segments" "$render_verdict" "$classification")
    local verdict verdict_marker
    verdict=$(printf '%s' "$verdict_out" | sed -n 's/^verdict=//p' | head -n 1)
    verdict_marker=$(printf '%s' "$verdict_out" | sed -n 's/^verdict_marker=//p' | head -n 1)

    # Production callers normally supply a witness, but the public helper is
    # also used directly by older/downstream gates. A failed result with an
    # omitted witness can still name a parseable location from its own log.
    # CLEAR records deliberately do not inspect their log: a warning-like
    # file:line must never turn a passing gate into a misleading failure.
    if [ -z "$witness" ] && [ "$verdict" != "clear" ]; then
        witness=$(extract_witness "$log")
    fi

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
    # duration_s: derived from the SAME started/ended ISO8601 UTC strings
    # already threaded through (never a new clock read) — jq's fromdateiso8601
    # is portable across macOS/Linux, unlike bash `date -d`/`date -j` diffing.
    # null (not 0) when either timestamp is unparseable/empty — a fabricated
    # 0s duration reads as "instant", which is the exact defect this field
    # exists to end (see pitch "build-cycle-accounts-for-its-own-time").
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
        --arg cycle_id "$cycle_id" \
        '($started | try fromdateiso8601 catch null) as $started_epoch
        | ($ended | try fromdateiso8601 catch null) as $ended_epoch
        | (if $started_epoch != null and $ended_epoch != null
           then ($ended_epoch - $started_epoch) else null end) as $duration_s
        | {
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
            duration_s: $duration_s,
            session_id: $session_id,
            log: $log,
            witness: $witness,
            graded_tree_sha: $graded_tree_sha,
            cycle_id: $cycle_id
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
