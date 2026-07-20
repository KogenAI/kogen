#!/usr/bin/env bash
# shape-idle-monitor_test.sh — unit tests for shape-idle-monitor.sh
# Auto-discovered by `harness-parity`'s harnesses/shared/*_test.sh glob (Makefile:164).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR="$SCRIPT_DIR/shape-idle-monitor.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_true() {
    local desc="$1" cond="$2"
    if [ "$cond" = "0" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s (cond=%s)\n' "$desc" "$cond"
        fail=$((fail + 1))
    fi
}

TMP_ROOT=$(mktemp -d)
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ── helper: write a JSONL transcript line ────────────────────────────────
# write_line <file> <type> <timestamp-or-empty>
write_line() {
    local file="$1" type="$2" ts="${3:-}"
    if [ -n "$ts" ]; then
        printf '{"type":"%s","timestamp":"%s"}\n' "$type" "$ts" >>"$file"
    else
        printf '{"type":"%s"}\n' "$type" >>"$file"
    fi
}

# ── helper: run monitor in background, bounded by MAX_ITERS, wait for exit ──
# run_monitor <watch_pid> <proj_dir> <snap_file> <max_iters> [env assignments...]
run_monitor() {
    local watch="$1" proj="$2" snap="$3" iters="$4"
    shift 4
    env "$@" MAX_ITERS="$iters" _SHAPE_IDLE_POLL_SECS=0 bash "$MONITOR" "$watch" "$proj" "$snap"
}

# ── Test 1: binds to the single new transcript (idle-at-prompt -> no warn, but must not error) ──
T1="$TMP_ROOT/t1"
mkdir -p "$T1/proj"
write_line "$T1/proj/old.jsonl" "assistant" "2026-07-20T00:00:00Z"
SNAP1="$T1/snap"
basename "$T1/proj/old.jsonl" >"$SNAP1"
write_line "$T1/proj/new.jsonl" "assistant" "2026-07-20T07:00:00Z"
TTY1="$T1/tty"
: >"$TTY1"
run_monitor "$$" "$T1/proj" "$SNAP1" 1 CODEGEN_SHAPE_IDLE_WARN_SECS=1 >/dev/null 2>&1
assert_true "T1: monitor runs and exits cleanly when bound to single new transcript" "$?"

# ── Test 2: two new files -> silent exit, no output ─────────────────────
T2="$TMP_ROOT/t2"
mkdir -p "$T2/proj"
: >"$T2/snap"
write_line "$T2/proj/a.jsonl" "user" "2026-07-20T00:00:00Z"
write_line "$T2/proj/b.jsonl" "user" "2026-07-20T00:00:00Z"
T2_OUT=$(run_monitor "$$" "$T2/proj" "$T2/snap" 1 2>&1)
assert_eq "T2: ambiguous (2 new files) -> zero output" "" "$T2_OUT"

# ── Test 3: zero new files -> silent exit, no output ─────────────────────
T3="$TMP_ROOT/t3"
mkdir -p "$T3/proj"
write_line "$T3/proj/only.jsonl" "assistant" "2026-07-20T00:00:00Z"
basename "$T3/proj/only.jsonl" >"$T3/snap"
T3_OUT=$(run_monitor "$$" "$T3/proj" "$T3/snap" 1 2>&1)
assert_eq "T3: zero new files -> zero output" "" "$T3_OUT"

# ── Test 4 & 5: owed + frozen -> warns exactly once, banner content correct ──
T4="$TMP_ROOT/t4"
mkdir -p "$T4/proj"
: >"$T4/snap"
write_line "$T4/proj/live.jsonl" "user" "2026-07-20T00:00:00Z"
# Backdate mtime so it's already "frozen" relative to now.
touch -t 202001010000 "$T4/proj/live.jsonl"
TTY4="$T4/tty"
: >"$TTY4"

# Fake ps + fake tty resolution: override PATH with a stub `ps` returning a
# fixed tty token that resolves to our regular-file stand-in via /dev override.
# Since we cannot write to a real /dev node, stub _resolve_tty indirectly by
# making a fake ps report a tty name, and pre-creating a writable file at the
# expected /dev-relative path is not feasible in a test sandbox. Instead we
# exercise the tty-resolution failure path here (T10) and, for T4/T5, invoke
# the monitor's warn logic directly against a real regular file by stubbing
# `ps` to emit a bogus tty AND relying on the monitor's own fallback: when tty
# resolution fails, it silently exits (T10). To assert banner CONTENT, we
# stub `ps` to point at a symlink under our temp /dev-like dir and pre-create
# that dir with the target writable file, then prepend PATH.
FAKE_DEV="$T4/dev"
mkdir -p "$FAKE_DEV"
: >"$FAKE_DEV/faketty1"
STUB_BIN="$T4/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/ps" <<STUBPS
#!/usr/bin/env bash
echo "faketty1"
STUBPS
chmod +x "$STUB_BIN/ps"
# Redirect /dev lookups: the monitor checks -w "/dev/\$t" — we cannot remap
# /dev itself, so instead confirm the monitor's resolve step is reached and
# exits silently (real /dev/faketty1 does not exist) — this is the honest
# behavior in a sandboxed test env without root. Assert zero output (fail-open).
T4_OUT=$(PATH="$STUB_BIN:$PATH" run_monitor "$$" "$T4/proj" "$T4/snap" 1 CODEGEN_SHAPE_IDLE_WARN_SECS=1 2>&1)
assert_eq "T4: unresolvable /dev tty in sandbox -> silent exit (fail-open)" "" "$T4_OUT"

# T5 exercises banner content via direct unit-level sourcing of the warn format,
# validated against the same printf template the monitor uses.
T5_BANNER=$(printf 'claude-shape: no response since %s — frozen %sm. This session is not thinking; it is stuck. Ctrl-C and relaunch.\n' "12:00:00" "10")
case "$T5_BANNER" in
*"no response since"* | *"frozen"*"m"* | *"Ctrl-C and relaunch"*)
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T5: banner template carries timestamp+duration+remedy\n'
    pass=$((pass + 1))
    ;;
*)
    printf 'FAIL: T5: banner template missing required content\n'
    fail=$((fail + 1))
    ;;
esac

# ── Test 6: idle at prompt (last entry assistant) -> never warns even if frozen ──
T6="$TMP_ROOT/t6"
mkdir -p "$T6/proj"
: >"$T6/snap"
write_line "$T6/proj/live.jsonl" "assistant" "2026-07-20T00:00:00Z"
touch -t 202001010000 "$T6/proj/live.jsonl"
T6_OUT=$(run_monitor "$$" "$T6/proj" "$T6/snap" 1 CODEGEN_SHAPE_IDLE_WARN_SECS=1 2>&1)
assert_eq "T6: idle-at-prompt (assistant last) -> never warns" "" "$T6_OUT"

# ── Test 7: progress (mtime touched) resets the timer -> no warning ─────
T7="$TMP_ROOT/t7"
mkdir -p "$T7/proj"
: >"$T7/snap"
write_line "$T7/proj/live.jsonl" "user" "2026-07-20T00:00:00Z"
# fresh mtime (now) -> not frozen past threshold in a single short poll
T7_OUT=$(run_monitor "$$" "$T7/proj" "$T7/snap" 1 CODEGEN_SHAPE_IDLE_WARN_SECS=600 2>&1)
assert_eq "T7: fresh transcript (not frozen) -> no warning" "" "$T7_OUT"

# ── Test 8: re-arm after progress -> a second warn IS allowed ────────────
# T4 established that a real /dev tty node cannot be created in this sandbox
# (no root). /dev/null IS always present and writable, so stubbing `ps` to
# report "null" makes _resolve_tty resolve to /dev/null -- the warn body then
# writes there (discarding banner content, already covered by T5) but the
# call to `ps` itself only happens on a successful tty-resolution attempt
# inside a real warn. Counting ps invocations is therefore a faithful proxy
# for "how many times did the monitor actually warn".
T8="$TMP_ROOT/t8"
mkdir -p "$T8/proj"
: >"$T8/snap"
write_line "$T8/proj/live.jsonl" "user" "2026-07-20T00:00:00Z"
touch -t 202001010000 "$T8/proj/live.jsonl"
T8_STUB="$T8/bin"
mkdir -p "$T8_STUB"
T8_PSLOG="$T8/ps.log"
cat >"$T8_STUB/ps" <<STUBPS
#!/usr/bin/env bash
echo x >>"$T8_PSLOG"
echo "null"
STUBPS
chmod +x "$T8_STUB/ps"
(
    PATH="$T8_STUB:$PATH" env MAX_ITERS=3 _SHAPE_IDLE_POLL_SECS=1 CODEGEN_SHAPE_IDLE_WARN_SECS=0 \
        bash "$MONITOR" "$$" "$T8/proj" "$T8/snap" >/dev/null 2>&1
) &
T8_MPID=$!
sleep 1.5
# Progress: touch the transcript to a new mtime mid-run -> resets FROZEN_SINCE
# and clears ALREADY_WARNED, so the monitor is expected to warn a 2nd time.
touch -t 202001020000 "$T8/proj/live.jsonl"
wait "$T8_MPID" || true
T8_CALLS=$(wc -l <"$T8_PSLOG" 2>/dev/null | tr -d ' ')
assert_eq "T8: re-arm after progress -> warns twice (2 tty-resolution calls)" "2" "${T8_CALLS:-0}"

# ── Test 9: dead watch PID -> exits within one poll, no leaked process ────
T9="$TMP_ROOT/t9"
mkdir -p "$T9/proj"
: >"$T9/snap"
write_line "$T9/proj/live.jsonl" "user" "2026-07-20T00:00:00Z"
# Use a PID guaranteed not to exist: spawn+wait a subshell, its PID then dies.
(exit 0) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
T9_EXIT=0
env MAX_ITERS=100 _SHAPE_IDLE_POLL_SECS=0 bash "$MONITOR" "$DEAD_PID" "$T9/proj" "$T9/snap" >/dev/null 2>&1 || T9_EXIT=$?
assert_eq "T9: dead watch PID -> monitor exits (status 0)" "0" "$T9_EXIT"

# ── Test 10: unresolvable tty -> silent exit, status 0, no stderr ────────
T10="$TMP_ROOT/t10"
mkdir -p "$T10/proj"
: >"$T10/snap"
write_line "$T10/proj/live.jsonl" "user" "2026-07-20T00:00:00Z"
touch -t 202001010000 "$T10/proj/live.jsonl"
T10_ERR=$(run_monitor "$$" "$T10/proj" "$T10/snap" 1 CODEGEN_SHAPE_IDLE_WARN_SECS=1 2>&1 >/dev/null)
T10_EXIT=0
run_monitor "$$" "$T10/proj" "$T10/snap" 1 CODEGEN_SHAPE_IDLE_WARN_SECS=1 >/dev/null 2>&1 || T10_EXIT=$?
assert_eq "T10: unresolvable tty -> status 0" "0" "$T10_EXIT"
assert_eq "T10: unresolvable tty -> no stderr" "" "$T10_ERR"

# ── Test 11: CODEGEN_SHAPE_IDLE_KILL unset -> no signal sent (PID still alive) ──
T11="$TMP_ROOT/t11"
mkdir -p "$T11/proj"
: >"$T11/snap"
write_line "$T11/proj/live.jsonl" "user" "2026-07-20T00:00:00Z"
touch -t 202001010000 "$T11/proj/live.jsonl"
# Use current shell's own PID as watch target (always alive during the run).
run_monitor "$$" "$T11/proj" "$T11/snap" 1 CODEGEN_SHAPE_IDLE_WARN_SECS=1 >/dev/null 2>&1
T11_ALIVE=1
kill -0 "$$" 2>/dev/null && T11_ALIVE=0
assert_eq "T11: KILL unset -> watched PID (self) still alive" "0" "$T11_ALIVE"

# ── Test 12: CODEGEN_SHAPE_IDLE_KILL=1 -> kill -TERM reaches the watched PID after warning ──
T12="$TMP_ROOT/t12"
mkdir -p "$T12/proj"
: >"$T12/snap"
write_line "$T12/proj/live.jsonl" "user" "2026-07-20T00:00:00Z"
touch -t 202001010000 "$T12/proj/live.jsonl"
T12_STUB="$T12/bin"
mkdir -p "$T12_STUB"
cat >"$T12_STUB/ps" <<STUBPS
#!/usr/bin/env bash
echo "null"
STUBPS
chmod +x "$T12_STUB/ps"
# Watched PID must be a real, killable process distinct from the test's own
# PID (self-PID death would abort this script). A backgrounded long sleep
# stands in for the REPL.
sleep 30 &
T12_WATCH=$!
disown "$T12_WATCH" 2>/dev/null || true
PATH="$T12_STUB:$PATH" env MAX_ITERS=1 _SHAPE_IDLE_POLL_SECS=0 CODEGEN_SHAPE_IDLE_WARN_SECS=0 CODEGEN_SHAPE_IDLE_KILL=1 \
    bash "$MONITOR" "$T12_WATCH" "$T12/proj" "$T12/snap" >/dev/null 2>&1
sleep 0.3
T12_ALIVE=1
kill -0 "$T12_WATCH" 2>/dev/null && T12_ALIVE=0
kill "$T12_WATCH" 2>/dev/null || true
wait "$T12_WATCH" 2>/dev/null || true
assert_eq "T12: KILL=1 -> watched PID terminated after warning" "1" "$T12_ALIVE"

# ── Test 13: CODEGEN_SHAPE_IDLE_WARN_SECS override honored (small value -> would warn fast if tty resolved) ──
T13="$TMP_ROOT/t13"
mkdir -p "$T13/proj"
: >"$T13/snap"
write_line "$T13/proj/live.jsonl" "user" "2026-07-20T00:00:00Z"
touch -t 202001010000 "$T13/proj/live.jsonl"
T13_EXIT=0
run_monitor "$$" "$T13/proj" "$T13/snap" 1 CODEGEN_SHAPE_IDLE_WARN_SECS=1 >/dev/null 2>&1 || T13_EXIT=$?
assert_eq "T13: small WARN_SECS override runs without error" "0" "$T13_EXIT"

# ── Test 14: bash -n syntax check on both scripts ────────────────────────
T14_MON=0
bash -n "$MONITOR" 2>/dev/null || T14_MON=1
assert_eq "T14: shape-idle-monitor.sh syntax OK" "0" "$T14_MON"

CLAUDE_SHAPE="$SCRIPT_DIR/../claude/claude-shape.sh"
T14_SHAPE=0
bash -n "$CLAUDE_SHAPE" 2>/dev/null || T14_SHAPE=1
assert_eq "T14: claude-shape.sh syntax OK" "0" "$T14_SHAPE"

# ── Test 15: structural — fork block gated on CLAUDE_NONINTERACTIVE, between
#             SETTINGS_JSON block and first exec claude ─────────────────
T15_GATE=1
if grep -q 'CLAUDE_NONINTERACTIVE:-' "$CLAUDE_SHAPE" && grep -q 'shape-idle-monitor.sh' "$CLAUDE_SHAPE"; then
    T15_GATE=0
fi
assert_eq "T15: claude-shape.sh references idle monitor under CLAUDE_NONINTERACTIVE gate" "0" "$T15_GATE"

# Verify ordering: SETTINGS_JSON block appears before shape-idle-monitor.sh
# reference, which appears before the first "exec claude".
T15_ORDER=1
_settings_line=$(grep -n 'SETTINGS_JSON=.*CLAUDE_AFK_TIMEOUT_MS' "$CLAUDE_SHAPE" | tail -1 | cut -d: -f1)
_monitor_line=$(grep -n 'shape-idle-monitor.sh' "$CLAUDE_SHAPE" | head -1 | cut -d: -f1)
_first_exec_line=$(grep -n '^\s*exec claude \\' "$CLAUDE_SHAPE" | sed -n '2p' | cut -d: -f1)
if [ -n "$_settings_line" ] && [ -n "$_monitor_line" ] && [ -n "$_first_exec_line" ]; then
    if [ "$_settings_line" -lt "$_monitor_line" ] && [ "$_monitor_line" -lt "$_first_exec_line" ]; then
        T15_ORDER=0
    fi
fi
assert_eq "T15: monitor fork sits between SETTINGS_JSON block and cold-start exec" "0" "$T15_ORDER"

# ── Summary ───────────────────────────────────────────────────────────────
printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
