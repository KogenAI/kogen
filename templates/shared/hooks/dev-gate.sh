#!/usr/bin/env bash
# dev-gate.sh — SubagentStop hook for phoenix-developer | data-layer-developer.
#
# Replaces the LLM verification-engineer's "decide and start the gate" step
# with a deterministic decision tree (see lib/gate-select.sh) and a
# launch protocol (inline for short gates, nohup background for long gates).
#
# Behaviour:
#   1. Loop guard: STOP_HOOK_ACTIVE=true → exit 0.
#   2. Skip if agent_type is not phoenix-developer or data-layer-developer.
#   3. Discover the active step log under <project>/codegen/logging/ (most
#      recently modified .md within the last 60 minutes), source
#      lib/gate-select.sh, call gate_select_decide → produces gate + mode.
#   4. SHORT gate → run inline. Exit 0 → log success and append synthetic
#      verification-engineer ALL CLEAR ✅ section. Non-zero → emit `block`
#      envelope so the developer is re-spawned with the failure reason.
#   5. LONG gate → launch via nohup, write the flag file at
#      <project>/codegen/gate-pending/<session_id>.flag and update the
#      latest.flag symlink. Append synthetic verification-engineer placeholder
#      noting "long gate started; awaiting Monitor verdict" so the orchestrator's
#      delegation-chain detector still sees the role marker.
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

if [ -z "$gate" ]; then
    debug_log dev-gate "no gate decided; skipping"
    exit 0
fi

debug_log dev-gate "gate='$gate' mode=$mode"

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

# ── LONG gate: launch background, write flag ────────────────────────────────
flag_dir="$project_dir/codegen/gate-pending"
mkdir -p "$flag_dir"

ts_safe=$(date -u +%Y%m%dT%H%M%SZ)
sid="${session_id:-nosession}"
log_path="$flag_dir/${sid}-${ts_safe}.log"
exitcode_path="${log_path}.exitcode"
flag_path="$flag_dir/${sid}.flag"

# Launch nohup, capture PID via $!.
nohup bash -c "$gate >$log_path 2>&1; echo \$? >$exitcode_path" >/dev/null 2>&1 &
launched_pid=$!

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

# Append placeholder VE section so the orchestrator's chain detector still
# sees the role marker. Real verdict comes from VE Monitor.
if [ -n "$log_file" ] && [ -w "$log_file" ]; then
    {
        printf '\n## verification-engineer Section\n\n'
        printf 'Gate: %s\n' "$gate"
        printf 'Ran: %s (background)\n\n' "$gate"
        printf '**Rules loaded**: deterministic hook (dev-gate.sh) — no rules loaded\n\n'
        printf '**Long gate started; awaiting Monitor verdict.**\n\n'
        printf '- Flag: %s\n' "$flag_path"
        printf '- PID: %s\n' "$launched_pid"
        printf '- Log: %s\n' "$log_path"
        printf '- Started: %s\n' "$started_at"
    } >>"$log_file"
fi

exit 0
