#!/usr/bin/env bash
# phoenix-dev-gate.sh — SubagentStop hook for developer-phoenix-backend | developer-phoenix-frontend.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: developer-phoenix-backend|developer-phoenix-frontend
# surface: user_global
# signal: AGENT_TYPE
# role: developer-phoenix-backend|developer-phoenix-frontend
# harnesses: all
#
# Replaces the prior agent-based "decide and start the gate" step
# with a deterministic decision tree (see lib/gate-select.sh) and a
# launch protocol (inline for short gates, foreground-poll for long gates).
#
# Behaviour:
#   1. Loop guard: STOP_HOOK_ACTIVE=true → exit 0.
#   2. Skip if agent_type is not developer-phoenix-backend or developer-phoenix-frontend.
#   3. Discover the active step log under <project>/codegen/logging/ (most
#      recently modified .md within the last 60 minutes), source
#      lib/gate-select.sh, call gate_select_decide → produces gate + mode + timeout.
#   4. SHORT gate → run inline. Exit 0 → log success and append synthetic
#      ALL CLEAR ✅ verdict section. Non-zero → emit `block`
#      envelope so the developer is re-spawned with the failure reason.
#   5. LONG gate → launch via nohup, write the flag file at
#      <project>/codegen/gate-pending/<session_id>.flag and update the
#      latest.flag symlink. Then BLOCK (foreground poll) for up to
#      $effective_timeout seconds waiting for the exitcode file. This is
#      intentional: the developer subagent's exit is held until the gate
#      verdict is ready, so the orchestrator sees the real verdict in the
#      step log immediately — no separate Monitor delegation needed.
#      INCONCLUSIVE verdicts carry an inline classification suffix
#      (seed-missing | pool-exhaustion | partial-gate | timeout-exceeded |
#      previous-gate-running | concurrent-launch) — no VE agent involved.
#
# Flag file format (key=value, one per line):
#   gate=<command>
#   pid=<pid>
#   log=<path>
#   exitcode_file=<path>
#   started_at=<ISO ts>
#   session_id=<id>
#   mode=long
#
# Invariant: latest.flag exists ⇔ a long gate is currently in flight.
# Created on long-gate launch (write near `ln -s "$flag_path"`).
# Removed on long-gate completion (all four verdict branches: timeout,
# ALL CLEAR, INCONCLUSIVE-environmental, FAILED).
# Swept at hook entry if its referenced exitcode_file exists as a regular
# file (i.e., the prior gate has terminated). Short gates do not write
# latest.flag.
#
# Planner-wins contract: if `## Plan` in the active step log contains a
# `**Gate**:` (or `Gate:`) line, that string is used verbatim, regardless
# of what the diff-based tree would have chosen. Document this in the log.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/gate-select.sh"
parse_input

# ── Stale-flag sweep helper ─────────────────────────────────────────────────
# Invariant: latest.flag exists ⇔ a long gate is currently in flight.
# Sweep: if latest.flag's referenced exitcode_file exists as a regular file,
# the gate has terminated → unlink latest.flag. Idempotent and safe: never
# touches a flag whose exitcode_file is absent (gate still running or never
# ran).
sweep_stale_latest_flag() {
    local flag_dir="$1"
    local latest="$flag_dir/latest.flag"
    [ -e "$latest" ] || return 0
    local ec
    ec=$(grep '^exitcode_file=' "$latest" 2>/dev/null | head -n 1 | cut -d= -f2-)
    if [ -n "$ec" ] && [ -f "$ec" ]; then
        rm -f "$latest"
        debug_log dev-gate "swept stale latest.flag (terminal exitcode_file=$ec)"
    fi
}

sweep_stale_latest_flag "${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}/codegen/gate-pending"

agent_type="$AGENT_TYPE"
session_id="$SESSION_ID"
project_dir="$CWD"

if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log dev-gate "skip: stop_hook_active session=$session_id"
    exit 0
fi

case "$agent_type" in
developer-phoenix-backend | developer-phoenix-frontend) ;;
*)
    debug_log dev-gate "skip: agent_type=$agent_type"
    exit 0
    ;;
esac

if [ -z "$project_dir" ]; then
    project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

cd "$project_dir" 2>/dev/null || {
    debug_log dev-gate "skip: could not cd to $project_dir"
    exit 0
}

debug_log dev-gate "fired cwd=$project_dir session=$session_id agent=$agent_type"

# ── Discover the active step log ────────────────────────────────────────────
log_file=$(session_log_from_transcript)
if [ -z "$log_file" ]; then
    debug_log dev-gate "skip: no session log in transcript"
    exit 0
fi

# ── Decide the gate ─────────────────────────────────────────────────────────
decision=$(gate_select_decide "$project_dir" "$log_file")
gate=$(printf '%s' "$decision" | sed -n 's/^gate=//p' | head -n 1)
mode=$(printf '%s' "$decision" | sed -n 's/^mode=//p' | head -n 1)
gate_timeout=$(printf '%s' "$decision" | sed -n 's/^timeout=//p' | head -n 1)

if [ -z "$gate" ]; then
    debug_log dev-gate "no gate decided; skipping"
    exit 0
fi

debug_log dev-gate "gate='$gate' mode=$mode timeout=$gate_timeout"

ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Classification helpers ──────────────────────────────────────────────────
# Each returns suffix string for `INCONCLUSIVE ⚠️ <suffix>`, or empty if signal
# absent. Composed cheapest → most specific. Deterministic signals from a fixed
# set replace the dropped LLM diagnostic role — no LLM round-trip.

classify_seed_missing() {
    # Only meaningful when the gate actually uses the seed (llm-phoenix targets).
    local gate="$1"
    [ -n "$gate" ] || return 0
    printf '%s' "$gate" | grep -qE 'llm-phoenix' || return 0
    local seed_dir="${OCG_PHOENIX_SEED_DIR:-}"
    if [ -z "$seed_dir" ]; then
        printf 'seed-missing (OCG_PHOENIX_SEED_DIR unset)'
        return 0
    fi
    local missing=""
    [ -f "$seed_dir/seed.bundle" ] || missing="seed.bundle"
    if [ -z "$missing" ] && [ ! -f "$seed_dir/seed.sql" ]; then
        missing="seed.sql"
    fi
    [ -n "$missing" ] && printf 'seed-missing (file: %s/%s)' "$seed_dir" "$missing"
}

classify_pool_exhaustion() {
    local log="$1"
    [ -f "$log" ] || return 0
    if grep -qE 'all workers busy|DBConnection\.ConnectionError|connection not available' "$log" 2>/dev/null; then
        printf 'pool-exhaustion'
    fi
}

classify_partial_gate() {
    local gate="$1" log="$2"
    [ -f "$log" ] || return 0
    local expected actual
    expected=$(printf '%s' "$gate" | awk -F'&&' '{print NF}')
    actual=$(grep -cE '^(make|mix) ' "$log" 2>/dev/null || echo 0)
    if [ "$expected" -gt 1 ] && [ "$actual" -lt "$expected" ]; then
        printf 'partial-gate (expected: %s, actual: %s)' "$expected" "$actual"
    fi
}

# Pick most specific classification. Falls back to `reason` (timeout-exceeded,
# previous-gate-running, concurrent-launch) when no other signal matches.
classify_inconclusive() {
    local gate="$1" log="$2" reason="$3"
    local out=""
    out=$(classify_seed_missing "$gate")
    [ -n "$out" ] && {
        printf '%s' "$out"
        return
    }
    out=$(classify_pool_exhaustion "$log")
    [ -n "$out" ] && {
        printf '%s' "$out"
        return
    }
    out=$(classify_partial_gate "$gate" "$log")
    [ -n "$out" ] && {
        printf '%s' "$out"
        return
    }
    printf '%s' "$reason"
}

append_ve_section() {
    local verdict="$1"
    local detail="$2"
    [ -n "$log_file" ] && [ -w "$log_file" ] || return 0
    local ts
    ts=$(ts_now)
    {
        printf '\n## dev-gate Section\n\n'
        printf 'Gate: %s\n' "$gate"
        printf 'Ran: %s\n\n' "$gate"
        printf '**Rules loaded**: deterministic hook (dev-gate.sh) — no rules loaded\n\n'
        printf '**Commands executed**:\n\n'
        printf '| Time (HH:MM:SS UTC) | Command | Exit | Notes |\n'
        printf '| ------------------- | ------- | ---- | ----- |\n'
        printf '| %s | %s | — | mode=%s |\n\n' "$ts" "$gate" "$mode"
        printf '**Result**: %s\n' "$verdict"
        if [ -n "$detail" ]; then
            printf '\n%s\n' "$detail"
        fi
    } >>"$log_file"
}

failed_suffix() {
    local prior=0
    local n
    if [ -f "$log_file" ]; then
        prior=$(
            grep -c 'FAILED ❌' "$log_file" 2>/dev/null
            true
        )
        [ -z "$prior" ] && prior=0
    fi
    n=$((prior + 1))
    [ "$n" -lt 2 ] && echo "attempt $n — dev-fixable" || echo "attempt $n — ROOT-CAUSE: route to planner"
}

# ── SHORT gate: run inline ──────────────────────────────────────────────────
if [ "$mode" = "short" ]; then
    log_path="/tmp/dev-gate-${session_id:-unknown}-$(date -u +%s).log"
    debug_log dev-gate "short-gate run: $gate (log=$log_path)"

    set +e
    bash -c "$gate" >"$log_path" 2>&1
    rc=$?
    set -e 2>/dev/null || true

    if [ "$rc" -eq 0 ]; then
        append_ve_section "ALL CLEAR ✅" ""
        debug_log dev-gate "short-gate exit=0; appended ALL CLEAR"
        exit 0
    fi

    tail_out=$(tail -n 40 "$log_path" 2>/dev/null || true)
    # Re-classify before FAILED in case it's environmental.
    short_seed=$(classify_seed_missing "$gate")
    short_pool=$(classify_pool_exhaustion "$log_path")
    if [ -n "$short_seed" ]; then
        append_ve_section "INCONCLUSIVE ⚠️ $short_seed" "Log: $log_path"
    elif [ -n "$short_pool" ]; then
        append_ve_section "INCONCLUSIVE ⚠️ $short_pool" "Log: $log_path"
    else
        block "Gate '$gate' failed (exit $rc). Log: $log_path. Tail:\n$tail_out"
        append_ve_section "FAILED ❌ exit=$rc ($(failed_suffix))" "Log: $log_path"
    fi
    exit 0
fi

# ── LONG gate: foreground-poll until verdict, then append it ─────────────────
#
# This branch INTENTIONALLY blocks the developer subagent's exit for up to
# $effective_timeout seconds. The subagent stays "stopped" until the gate
# completes, so the orchestrator sees the real verdict in the step log
# immediately. INCONCLUSIVE verdicts include a classification suffix the
# orchestrator looks up in `codegen/rules/roles/orchestrator.md`
# § INCONCLUSIVE table — no VE agent involved.

flag_dir="$project_dir/codegen/gate-pending"

# ── Pre-launch reaper ───────────────────────────────────────────────────────
# If a previous gate is still running, don't launch a new one.
if [ -e "$flag_dir/latest.flag" ]; then
    prev_pid=$(grep '^pid=' "$flag_dir/latest.flag" 2>/dev/null | cut -d= -f2-)
    if [ -n "$prev_pid" ] && kill -0 "$prev_pid" 2>/dev/null; then
        prev_start=$(grep '^started_at=' "$flag_dir/latest.flag" 2>/dev/null | cut -d= -f2-)
        debug_log dev-gate "previous gate pid=$prev_pid still alive; skipping new launch"
        append_ve_section "INCONCLUSIVE ⚠️ previous-gate-running (PID: $prev_pid, started: $prev_start)" \
            "A previous gate (PID $prev_pid) is still running. No new gate launched. Check flag: $flag_dir/latest.flag"
        exit 0
    fi
    # Previous PID is dead — sweep orphan log/exitcode files older than 24h.
    find "$flag_dir" -name '*.log' -mtime +1 -delete 2>/dev/null || true
    find "$flag_dir" -name '*.exitcode' -mtime +1 -delete 2>/dev/null || true
fi

mkdir -p "$flag_dir"

# ── Stale-lock recovery ─────────────────────────────────────────────────────
# If .launch.lock exists but its recorded PID is dead, the previous hook
# crashed mid-launch. Remove the stale lock so we can proceed.
if [ -d "$flag_dir/.launch.lock" ]; then
    lock_pid_file="$flag_dir/.launch.lock/launched_pid"
    if [ -f "$lock_pid_file" ]; then
        lock_pid=$(cat "$lock_pid_file")
        if ! kill -0 "$lock_pid" 2>/dev/null; then
            debug_log dev-gate "stale lock from dead pid=$lock_pid; removing"
            rm -rf "$flag_dir/.launch.lock"
        fi
    else
        # Lock dir without PID file — orphan from a crash before PID was written.
        rm -rf "$flag_dir/.launch.lock"
    fi
fi

# ── Mutex ───────────────────────────────────────────────────────────────────
if ! mkdir "$flag_dir/.launch.lock" 2>/dev/null; then
    other_pid=""
    [ -f "$flag_dir/.launch.lock/launched_pid" ] && other_pid=$(cat "$flag_dir/.launch.lock/launched_pid" 2>/dev/null)
    debug_log dev-gate "concurrent launch detected; skipping"
    append_ve_section "INCONCLUSIVE ⚠️ concurrent-launch (other PID: ${other_pid:-unknown})" \
        "Another dev-gate launch is already in progress (lock: $flag_dir/.launch.lock)."
    exit 0
fi
trap 'rm -rf "$flag_dir/.launch.lock"' EXIT INT TERM

ts_safe=$(date -u +%Y%m%dT%H%M%SZ)
sid="${session_id:-nosession}"
log_path="$flag_dir/${sid}-${ts_safe}.log"
exitcode_path="${log_path}.exitcode"
flag_path="$flag_dir/${sid}.flag"

# ── Launch ──────────────────────────────────────────────────────────────────
# Subshell-detach pattern: the inner subshell forks the gate with nohup and
# immediately exits, reparenting the grandchild to PID 1 (launchd/init).
# This makes the gate immune to PGID kills — Claude Code SIGKILLs the process
# group on Bash tool timeout; nohup alone only protects against SIGHUP.
# The outer `wait $!` waits for the subshell to exit (fast — fork + echo PID),
# then we read the grandchild PID from the tmp file.
launched_pid_tmp="$flag_dir/.launch.lock/launched_pid_tmp"
(
    nohup bash -c "{ $gate; } >\"$log_path\" 2>&1; echo \$? >\"$exitcode_path\"" >/dev/null 2>&1 &
    echo $! >"$launched_pid_tmp"
) &
wait $!
launched_pid=$(cat "$launched_pid_tmp" 2>/dev/null || echo "")
rm -f "$launched_pid_tmp"
if [[ -z "$launched_pid" ]]; then
    append_ve_section "INCONCLUSIVE ⚠️ launch-failed" "Could not capture detached gate PID."
    exit 0
fi

# Record PID in lock dir so stale-lock recovery can check it later.
echo "$launched_pid" >"$flag_dir/.launch.lock/launched_pid"

started_at=$(ts_now)

cat >"$flag_path" <<EOF
gate=$gate
pid=$launched_pid
log=$log_path
exitcode_file=$exitcode_path
started_at=$started_at
session_id=$sid
mode=long
EOF

# Update latest.flag → <sid>.flag (overwrite atomically). Use ln -sf for
# robustness across reruns; remove first to avoid lingering broken links.
rm -f "$flag_dir/latest.flag"
ln -s "$flag_path" "$flag_dir/latest.flag" 2>/dev/null ||
    cp "$flag_path" "$flag_dir/latest.flag"

debug_log dev-gate "long-gate launched pid=$launched_pid flag=$flag_path"

# ── Read timeout from gate-select output ────────────────────────────────────
effective_timeout="${DEV_GATE_POLL_TIMEOUT_OVERRIDE:-$gate_timeout}"
[ -n "$effective_timeout" ] && [ "$effective_timeout" -gt 0 ] || effective_timeout=900

debug_log dev-gate "polling timeout=${effective_timeout}s exitcode=$exitcode_path"

# ── Foreground poll loop ────────────────────────────────────────────────────
# Blocks the developer subagent's exit until the gate produces an exitcode
# file or the timeout is exceeded. Heartbeats every 60s via debug_log.
elapsed=0
while [ "$elapsed" -lt "$effective_timeout" ]; do
    [ -f "$exitcode_path" ] && break
    sleep 5
    elapsed=$((elapsed + 5))
    [ $((elapsed % 60)) -eq 0 ] && debug_log dev-gate "polling long gate elapsed=$elapsed/$effective_timeout"
done

# ── Classify and append verdict ─────────────────────────────────────────────
if [ ! -f "$exitcode_path" ]; then
    debug_log dev-gate "long-gate timed out after ${elapsed}s"
    classification=$(classify_inconclusive "$gate" "$log_path" "timeout-exceeded")
    append_ve_section "INCONCLUSIVE ⚠️ $classification" \
        "Gate '$gate' did not complete within ${effective_timeout}s. Log: $log_path"
elif [ "$(cat "$exitcode_path")" = "0" ]; then
    debug_log dev-gate "long-gate exit=0; appended ALL CLEAR"
    append_ve_section "ALL CLEAR ✅" "Gate '$gate' passed. Log: $log_path"
else
    rc=$(cat "$exitcode_path")
    tail_out=$(tail -n 40 "$log_path" 2>/dev/null || true)
    # Pool exhaustion / seed missing should be INCONCLUSIVE not FAILED — they're
    # environmental, not code-level. Re-check before emitting FAILED.
    classification=""
    pool_check=$(classify_pool_exhaustion "$log_path")
    seed_check=$(classify_seed_missing "$gate")
    if [ -n "$seed_check" ]; then
        classification="$seed_check"
    elif [ -n "$pool_check" ]; then
        classification="$pool_check"
    fi
    if [ -n "$classification" ]; then
        debug_log dev-gate "long-gate exit=$rc classified as $classification"
        append_ve_section "INCONCLUSIVE ⚠️ $classification" \
            "$(printf 'Gate '"'"'%s'"'"' failed exit=%s (environmental). Log: %s\n\nTail:\n%s' "$gate" "$rc" "$log_path" "$tail_out")"
    else
        debug_log dev-gate "long-gate exit=$rc; appended FAILED"
        append_ve_section "FAILED ❌ exit=$rc ($(failed_suffix))" \
            "$(printf 'Gate '"'"'%s'"'"' failed. Log: %s\n\nTail:\n%s' "$gate" "$log_path" "$tail_out")"
    fi
fi

rm -f "$flag_dir/latest.flag"

exit 0
