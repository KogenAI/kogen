#!/bin/sh
# Offline checks for the Kogen specification. Installs nothing.
# Node modules come from ./node_modules (npm ci, once) or $KOGEN_SPEC_NODE_MODULES.
set -eu
cd "$(dirname "$0")"
NM="${KOGEN_SPEC_NODE_MODULES:-$PWD/node_modules}"
export KOGEN_SPEC_NODE_MODULES="$NM"
Q="$NM/.bin/quint"
[ -x "$Q" ] || { echo "check: quint not found in $NM (run npm ci in spec/ or set KOGEN_SPEC_NODE_MODULES)"; exit 3; }
[ "$("$Q" --version)" = "0.33.0" ] || { echo "check: quint must be 0.33.0"; exit 3; }

echo "== Gherkin parse, tags, requirement coverage, step vocabulary, trace"
node tools/check.mjs

# Recorded seeds and bounds (change them only together with this README section).
run() { # file invariant seed samples steps
  echo "== quint run $1 --invariant $2 (seed $3, $4 samples, $5 steps)"
  out=$("$Q" run --backend typescript "quint/$1" --invariant "$2" --seed "$3" --max-samples "$4" --max-steps "$5" 2>&1) || { echo "$out"; echo "check: invariant $2 violated in $1"; exit 1; }
  echo "$out" | grep -E '^\[ok\]'
}
for f in shaping build run_control; do
  echo "== quint typecheck + test $f.qnt"
  "$Q" typecheck "quint/$f.qnt"
  out=$("$Q" test --backend typescript "quint/$f.qnt" --match Test --seed 1 --max-samples 50 2>&1) || { echo "$out"; echo "check: quint tests failed in $f.qnt"; exit 1; }
  echo "$out" | grep -E 'passing'
done
run shaping.qnt Safety 7 2000 20
run build.qnt Safety 11 3000 60
run run_control.qnt Safety 3 3000 30

# Non-vacuity: a deliberately false claim must be refuted by an actual counterexample
# ("[violation]" and "error: Invariant violated"), so the simulator reaches the states
# the invariants talk about. Any other failure (parse error, unknown name, crash) fails
# the check instead of counting as a counterexample.
refute() { # file expression seed
  if out=$("$Q" run --backend typescript "quint/$1" --invariant "$2" --seed "$3" --max-samples 3000 --max-steps 60 2>&1); then
    echo "check: non-vacuity failed: $1 never reached not($2)"; exit 1
  fi
  if ! printf '%s\n' "$out" | grep -q '^\[violation\]' || ! printf '%s\n' "$out" | grep -q '^error: Invariant violated$'; then
    printf '%s\n' "$out" | tail -5
    echo "check: quint failed on $1 without a counterexample for not($2)"; exit 1
  fi
  echo "== non-vacuity ok: $1 reaches not($2)"
}
refute shaping.qnt 'st != Building' 7
refute shaping.qnt 'st != Built' 7
refute build.qnt 'phase != Done' 11
refute build.qnt 'reason != "baseline_changed"' 11
refute build.qnt 'reason != "review_invalid"' 11
refute build.qnt 'reason != "review_blocked"' 11
refute build.qnt 'reason != "build_blocked"' 11
refute build.qnt 'reason != "head_moved"' 11
refute build.qnt 'reason != "context_exhausted"' 11
refute build.qnt 'reason != "provider"' 11
refute build.qnt 'reason != "commit_failed"' 11
refute build.qnt 'reason != "hook_changed_commit"' 11
refute build.qnt 'phase != Interrupted' 11
refute run_control.qnt 'not(status == Ended and signal == SigInt)' 3
refute run_control.qnt 'not(status == Ended and signal == SigTerm)' 3
refute run_control.qnt 'not(status == Ended and signal == SigHup)' 3
refute run_control.qnt 'not(status == Ended and signal == InternalError)' 3
refute run_control.qnt 'not(status == Ended and signal == InternalError and committed)' 3
refute run_control.qnt 'refusal != "build_running"' 3
echo "spec checks: all ok"
