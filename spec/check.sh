#!/bin/sh
# Offline checks for the Kogen specification. Installs nothing.
# Node modules come from ./node_modules (npm ci, once) or $KOGEN_SPEC_NODE_MODULES.
# The Quint runs are independent, so they run in up to $KOGEN_SPEC_JOBS lanes at once (default:
# half the CPU count, from 2 to 4: a Quint run keeps about two cores busy); their output is printed in the fixed order below and the first
# failing one in that order decides the result, exactly as in a sequential run.
set -eu
cd "$(dirname "$0")"
NM="${KOGEN_SPEC_NODE_MODULES:-$PWD/node_modules}"
export KOGEN_SPEC_NODE_MODULES="$NM"
Q="$NM/.bin/quint"
[ -x "$Q" ] || { echo "check: quint not found in $NM (run npm ci in spec/ or set KOGEN_SPEC_NODE_MODULES)"; exit 3; }
[ "$("$Q" --version)" = "0.33.0" ] || { echo "check: quint must be 0.33.0"; exit 3; }

echo "== Gherkin parse, tags, requirement coverage, step vocabulary, trace"
node tools/check.mjs

JOBS="${KOGEN_SPEC_JOBS:-$( (nproc || getconf _NPROCESSORS_ONLN || sysctl -n hw.ncpu) 2>/dev/null | head -n 1)}"
case "$JOBS" in ''|*[!0-9]*|0) JOBS=1 ;; esac
if [ -z "${KOGEN_SPEC_JOBS:-}" ]; then
  JOBS=$((JOBS / 2))
  [ "$JOBS" -lt 2 ] && JOBS=2
  [ "$JOBS" -gt 4 ] && JOBS=4
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/kogen-spec-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
# On an interrupt, stop the lanes and every Quint run below them, so nothing is left running.
descendants() { for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
stop_all() {
  trap '' INT TERM HUP
  all=""
  for p in $(jobs -p); do all="$all $p $(descendants "$p")"; done
  # shellcheck disable=SC2086
  [ -z "$all" ] || kill $all 2>/dev/null || true
  wait 2>/dev/null || true
  exit 130
}
trap stop_all INT TERM HUP
N=0

# task NAME CMD...: CMD is a shell function; its output and status go to $T/N.out and $T/N.rc.
add() { N=$((N + 1)); eval "task_$N() { $*; }"; }

# Recorded seeds and bounds (change them only together with this README section).
run() { # file invariant seed samples steps
  echo "== quint run $1 --invariant $2 (seed $3, $4 samples, $5 steps)"
  out=$("$Q" run --backend typescript "quint/$1" --invariant "$2" --seed "$3" --max-samples "$4" --max-steps "$5" 2>&1) || { echo "$out"; echo "check: invariant $2 violated in $1"; return 1; }
  echo "$out" | grep -E '^\[ok\]'
}
typecheck_test() { # model
  echo "== quint typecheck + test $1.qnt"
  "$Q" typecheck "quint/$1.qnt" || return 1
  out=$("$Q" test --backend typescript "quint/$1.qnt" --match Test --seed 1 --max-samples 50 2>&1) || { echo "$out"; echo "check: quint tests failed in $1.qnt"; return 1; }
  echo "$out" | grep -E 'passing'
}

# Non-vacuity: a deliberately false claim must be refuted by an actual counterexample
# ("[violation]" and "error: Invariant violated"), so the simulator reaches the states
# the invariants talk about. Any other failure (parse error, unknown name, crash) fails
# the check instead of counting as a counterexample.
refute() { # file expression seed
  if out=$("$Q" run --backend typescript "quint/$1" --invariant "$2" --seed "$3" --max-samples 3000 --max-steps 60 2>&1); then
    echo "check: non-vacuity failed: $1 never reached not($2)"; return 1
  fi
  if ! printf '%s\n' "$out" | grep -q '^\[violation\]' || ! printf '%s\n' "$out" | grep -q '^error: Invariant violated$'; then
    printf '%s\n' "$out" | tail -5
    echo "check: quint failed on $1 without a counterexample for not($2)"; return 1
  fi
  echo "== non-vacuity ok: $1 reaches not($2)"
}

for f in shaping build run_control; do add typecheck_test "$f"; done
add run shaping.qnt Safety 7 2000 20
add run build.qnt Safety 11 3000 60
add run run_control.qnt Safety 3 3000 30
add refute shaping.qnt "'st != Building'" 7
add refute shaping.qnt "'st != Built'" 7
add refute build.qnt "'phase != Done'" 11
add refute build.qnt "'reason != \"baseline_changed\"'" 11
add refute build.qnt "'reason != \"review_invalid\"'" 11
add refute build.qnt "'reason != \"review_blocked\"'" 11
add refute build.qnt "'reason != \"build_blocked\"'" 11
add refute build.qnt "'reason != \"head_moved\"'" 11
add refute build.qnt "'reason != \"context_exhausted\"'" 11
add refute build.qnt "'reason != \"provider\"'" 11
add refute build.qnt "'reason != \"commit_failed\"'" 11
add refute build.qnt "'reason != \"hook_changed_commit\"'" 11
add refute build.qnt "'phase != Interrupted'" 11
add refute run_control.qnt "'not(status == Ended and signal == SigInt)'" 3
add refute run_control.qnt "'not(status == Ended and signal == SigTerm)'" 3
add refute run_control.qnt "'not(status == Ended and signal == SigHup)'" 3
add refute run_control.qnt "'not(status == Ended and signal == InternalError)'" 3
add refute run_control.qnt "'not(status == Ended and signal == InternalError and committed)'" 3
add refute run_control.qnt "'refusal != \"build_running\"'" 3

# Lane L runs tasks L, L+JOBS, ... in order. The Quint simulations come first, so they spread
# over the lanes before the short checks fill them. As in a sequential run, nothing starts after
# a failure: a task is skipped once a task before it has failed (tasks already running finish).
earlier_failed() { # n
  for f in "$T"/fail.*; do
    [ -e "$f" ] || continue
    [ "${f##*.}" -lt "$1" ] && return 0
  done
  return 1
}
lane() {
  n=$1
  while [ "$n" -le "$N" ]; do
    if earlier_failed "$n"; then :
    elif "task_$n" >"$T/$n.out" 2>&1; then echo 0 >"$T/$n.rc"
    else echo 1 >"$T/$n.rc"; : >"$T/fail.$n"; fi
    n=$((n + JOBS))
  done
}
l=1
while [ "$l" -le "$JOBS" ] && [ "$l" -le "$N" ]; do lane "$l" & l=$((l + 1)); done
wait

n=1
while [ "$n" -le "$N" ]; do
  cat "$T/$n.out"
  [ "$(cat "$T/$n.rc")" = 0 ] || exit 1
  n=$((n + 1))
done
echo "spec checks: all ok"
