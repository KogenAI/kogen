#!/usr/bin/env bash
# gate-control.sh — Helper library for gate in-flight status, log tailing,
# and gate termination.
#
# Sourceable. Functions:
#
#   gate_control_status <project_dir>
#       Reads <project_dir>/codegen/gate-pending/latest.flag.
#       Validates PID liveness with start-time anti-reuse guard.
#       Exit 0  + prints summary if gate is genuinely in-flight (PID alive, times match).
#       Exit 1  if no flag, PID dead, or start-time mismatch (not in-flight).
#       Sweeps orphan flags when PID is dead.
#
#   gate_control_logs <project_dir>
#       Reads log path from latest.flag and tails the file.
#       Exits 1 if no flag or log absent.
#
#   gate_control_kill <project_dir>
#       Terminates the in-flight gate via kill -TERM -<pgid> (process group).
#       Falls back to kill -TERM <pid> if pgid absent in flag.
#       Exits 1 if no flag or PID dead.
#
# PID start-time validation:
#   The flag file records started_at=<ISO timestamp>.  We compare this against
#   the process start time from `ps -o lstart= -p <pid>` to guard against PID
#   reuse: if the process started significantly later than the flag's started_at,
#   we treat it as a different process and consider the gate not in-flight.

set -u

# _flag_path <project_dir> — print path to latest.flag (may not exist)
_flag_path() {
    printf '%s/codegen/gate-pending/latest.flag' "$1"
}

# _read_flag_field <flag_file> <key>
_read_flag_field() {
    local flag="$1" key="$2"
    grep "^${key}=" "$flag" 2>/dev/null | head -n 1 | cut -d= -f2-
}

# _pid_started_epoch <pid>
# Returns the process start time as epoch seconds, or "" on error.
_pid_started_epoch() {
    local pid="$1"
    # ps -o lstart= prints something like "Sat Jun  7 12:00:00 2026"
    local lstart
    lstart=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')
    [ -z "$lstart" ] && {
        printf ''
        return 0
    }
    # Convert to epoch. On macOS: date -j -f "%a %b %e %H:%M:%S %Y"
    # On Linux: date -d "$lstart"
    local epoch=""
    if date --version >/dev/null 2>&1; then
        # GNU date
        epoch=$(date -d "$lstart" +%s 2>/dev/null || true)
    else
        # BSD date (macOS)
        epoch=$(date -j -f "%a %b %e %H:%M:%S %Y" "$lstart" +%s 2>/dev/null || true)
    fi
    printf '%s' "$epoch"
}

# _iso_to_epoch <iso_timestamp>
# Converts "2026-06-07T12:00:00Z" to epoch seconds.
_iso_to_epoch() {
    local ts="$1"
    local epoch=""
    if date --version >/dev/null 2>&1; then
        epoch=$(date -d "$ts" +%s 2>/dev/null || true)
    else
        # BSD date — strip T and Z for parsing
        local ts_clean
        ts_clean=$(printf '%s' "$ts" | sed 's/T/ /; s/Z//')
        epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$ts_clean" +%s 2>/dev/null || true)
    fi
    printf '%s' "$epoch"
}

# gate_control_status <project_dir>
# Exit 0 if gate is genuinely in-flight; exit 1 otherwise.
gate_control_status() {
    local project_dir="$1"
    local flag
    flag=$(_flag_path "$project_dir")

    if [ ! -e "$flag" ]; then
        return 1
    fi

    local pid gate started_at pgid
    pid=$(_read_flag_field "$flag" pid)
    gate=$(_read_flag_field "$flag" gate)
    started_at=$(_read_flag_field "$flag" started_at)
    pgid=$(_read_flag_field "$flag" pgid)

    if [ -z "$pid" ]; then
        # Malformed flag — not in-flight
        return 1
    fi

    # Check PID liveness
    if ! kill -0 "$pid" 2>/dev/null; then
        # PID dead — sweep orphan flag
        rm -f "$flag" 2>/dev/null || true
        return 1
    fi

    # PID alive — validate start time to guard against PID reuse
    if [ -n "$started_at" ]; then
        local flag_epoch proc_epoch
        flag_epoch=$(_iso_to_epoch "$started_at")
        proc_epoch=$(_pid_started_epoch "$pid")

        if [ -n "$flag_epoch" ] && [ -n "$proc_epoch" ]; then
            local diff
            # Allow up to 12 hours absolute tolerance. Rationale: ps -o lstart=
            # returns local time but started_at in the flag is UTC, so we cannot
            # do exact comparison cross-platform. 12h covers all real UTC offsets
            # (UTC-12 to UTC+14). A recycled PID started years ago/in the future
            # will have |diff| >> 12h and be correctly rejected.
            diff=$((proc_epoch - flag_epoch))
            if [ "$diff" -lt 0 ]; then diff=$((-diff)); fi
            if [ "$diff" -gt 43200 ]; then
                # Start-time differs by more than 12h — PID reuse.
                rm -f "$flag" 2>/dev/null || true
                return 1
            fi
        fi
    fi

    # Gate is genuinely in-flight
    printf 'gate in-flight: gate=%s pid=%s pgid=%s started=%s flag=%s\n' \
        "$gate" "$pid" "${pgid:-N/A}" "$started_at" "$flag"
    return 0
}

# gate_control_logs <project_dir>
# Prints the last 50 lines of the gate's log file.
gate_control_logs() {
    local project_dir="$1"
    local flag
    flag=$(_flag_path "$project_dir")

    if [ ! -e "$flag" ]; then
        printf 'gate_control_logs: no latest.flag at %s\n' "$flag" >&2
        return 1
    fi

    local log_path
    log_path=$(_read_flag_field "$flag" log)

    if [ -z "$log_path" ] || [ ! -f "$log_path" ]; then
        printf 'gate_control_logs: log not found: %s\n' "${log_path:-<empty>}" >&2
        return 1
    fi

    # Read last 50 lines from log
    local lines
    lines=$(awk '{lines[NR]=$0} END{start=(NR>50)?(NR-49):1; for(i=start;i<=NR;i++) print lines[i]}' "$log_path" 2>/dev/null || true)
    printf '%s\n' "$lines"
}

# gate_control_kill <project_dir>
# Terminates the in-flight gate. Prefers kill -TERM -<pgid>; falls back to kill -TERM <pid>.
gate_control_kill() {
    local project_dir="$1"
    local flag
    flag=$(_flag_path "$project_dir")

    if [ ! -e "$flag" ]; then
        printf 'gate_control_kill: no latest.flag at %s\n' "$flag" >&2
        return 1
    fi

    local pid pgid
    pid=$(_read_flag_field "$flag" pid)
    pgid=$(_read_flag_field "$flag" pgid)

    if [ -z "$pid" ]; then
        printf 'gate_control_kill: no pid in flag\n' >&2
        return 1
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        printf 'gate_control_kill: PID %s is already dead\n' "$pid" >&2
        rm -f "$flag" 2>/dev/null || true
        return 1
    fi

    if [ -n "$pgid" ]; then
        kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        printf 'gate_control_kill: sent SIGTERM to pgid=%s (pid=%s)\n' "$pgid" "$pid"
    else
        kill -TERM "$pid" 2>/dev/null || true
        printf 'gate_control_kill: sent SIGTERM to pid=%s (no pgid in flag)\n' "$pid"
    fi
}
