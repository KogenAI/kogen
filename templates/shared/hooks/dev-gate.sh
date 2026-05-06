#!/usr/bin/env bash
# dev-gate.sh — SubagentStop hook for phoenix-developer | data-layer-developer.
#
# Replaces the LLM verification-engineer's "decide and start the gate" step
# with a deterministic decision tree (see lib/gate-select.sh) and a
# launch protocol (inline for short gates, foreground-poll for long gates).
#
# Behaviour:
#   1. Loop guard: STOP_HOOK_ACTIVE=true → exit 0.
#   2. Skip if agent_type is not phoenix-developer or data-layer-developer.
#   3. Discover the active step log under <project>/codegen/logging/ (most
#      recently modified .md within the last 60 minutes), source
#      lib/gate-select.sh, call gate_select_decide → produces gate + mode + timeout.
#   4. SHORT gate → run inline. Exit 0 → log success and append synthetic
#      verification-engineer ALL CLEAR ✅ section. Non-zero → emit `block`
#      envelope so the developer is re-spawned with the failure reason.
#   5. LONG gate → launch via nohup, write the flag file at
#      <project>/codegen/gate-pending/<session_id>.flag and update the
#      latest.flag symlink. Then BLOCK (foreground poll) for up to
#      $effective_timeout seconds waiting for the exitcode file. This is
#      intentional: the developer subagent's exit is held until the gate
#      verdict is ready, so the orchestrator sees the real verdict in the
#      step log immediately — no separate VE Monitor delegation needed.
#      VE is only invoked when the verdict is INCONCLUSIVE.
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
# Planner-wins contract: if `## Plan` in the active step log contains a
# `**Gate**:` (or `Gate:`) line, that string is used verbatim, regardless
# of what the diff-based tree would have chosen. Document this in the log.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/gate-select.sh"
parse_input

agent_type="$AGENT_TYPE"
session_id="$SESSION_ID"
project_dir="$CWD"

if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log dev-gate "skip: stop_hook_active session=$session_id"
    exit 0
fi

case "$agent_type" in
phoenix-developer | data-layer-developer) ;;
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
logging_dir="$project_dir/codegen/logging"
log_file=""
if [ -d "$logging_dir" ]; then
    log_file=$(find "$logging_dir" -maxdepth 1 -type f -name '*.md' -mmin -60 2>/dev/null |
        xargs -I{} stat -f '%m %N' {} 2>/dev/null |
        sort -rn |
        head -n 1 |
        awk '{$1=""; sub(/^ /, ""); print}')
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

append_ve_section() {
    local verdict="$1"
    local detail="$2"
    [ -n "$log_file" ] && [ -w "$log_file" ] || return 0
    local ts
    ts=$(ts_now)
    {
        printf '\n## verification-engineer Section\n\n'
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
    block "Gate '$gate' failed (exit $rc). Log: $log_path. Tail:\n$tail_out"
    append_ve_section "FAILED ❌ exit=$rc" "Log: $log_path"
    exit 0
fi

# ── LONG gate: foreground-poll until verdict, then append it ─────────────────
#
# This branch INTENTIONALLY blocks the developer subagent's exit for up to
# $effective_timeout seconds. The subagent stays "stopped" until the gate
# completes, so the orchestrator sees the real verdict in the step log
# immediately — no separate VE Monitor delegation is needed for normal cases.
# VE is only invoked when the verdict is INCONCLUSIVE (timeout, crash, etc.).

flag_dir="$project_dir/codegen/gate-pending"

# ── Pre-launch reaper ───────────────────────────────────────────────────────
# If a previous gate is still running, don't launch a new one.
if [ -e "$flag_dir/latest.flag" ]; then
    prev_pid=$(grep '^pid=' "$flag_dir/latest.flag" 2>/dev/null | cut -d= -f2-)
    if [ -n "$prev_pid" ] && kill -0 "$prev_pid" 2>/dev/null; then
        debug_log dev-gate "previous gate pid=$prev_pid still alive; skipping new launch"
        append_ve_section "INCONCLUSIVE ⚠️ previous-gate-running" \
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
    debug_log dev-gate "concurrent launch detected; skipping"
    append_ve_section "INCONCLUSIVE ⚠️ concurrent-launch" \
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
# nohup so the gate survives if the hook is killed, but we poll it inline.
nohup bash -c "$gate >$log_path 2>&1; echo \$? >$exitcode_path" >/dev/null 2>&1 &
launched_pid=$!

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
    append_ve_section "INCONCLUSIVE ⚠️ timeout-exceeded" \
        "Gate '$gate' did not complete within ${effective_timeout}s. Log: $log_path"
elif [ "$(cat "$exitcode_path")" = "0" ]; then
    debug_log dev-gate "long-gate exit=0; appended ALL CLEAR"
    append_ve_section "ALL CLEAR ✅" "Gate '$gate' passed. Log: $log_path"
else
    rc=$(cat "$exitcode_path")
    tail_out=$(tail -n 40 "$log_path" 2>/dev/null || true)
    debug_log dev-gate "long-gate exit=$rc; appended FAILED"
    append_ve_section "FAILED ❌ exit=$rc" \
        "$(printf 'Gate '"'"'%s'"'"' failed. Log: %s\n\nTail:\n%s' "$gate" "$log_path" "$tail_out")"
fi

exit 0
