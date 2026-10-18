#!/bin/sh
# Regression check for real-use.sh's verification: an early failing command with a passing last
# command must fail the check (it once passed because the last command decided).
here=$(cd "$(dirname "$0")" && pwd)
log=/dev/null
fail() { echo "failed: $*"; exit 1; }
. "$here/checked.sh"

verify_without_kogen() { false; true; }
set +e; out=$( verify_project ); code=$?; set -e
[ "$code" -ne 0 ] && [ "$out" = "failed: the project's own checks fail on the new commit (status 1)" ] || { echo "check-verify: an early failure was masked (exit $code, output $out)"; exit 1; }

verify_without_kogen() { true; true; }
set +e; out=$( verify_project ); code=$?; set -e
[ "$code" -eq 0 ] || { echo "check-verify: a passing verification failed (exit $code, output $out)"; exit 1; }
run_dir=$(mktemp -d)
trap 'rm -rf "$run_dir"' EXIT
set +e; out=$( run_logged sh -c 'echo init-refused; exit 4' ); code=$?; set -e
[ "$code" -ne 0 ] && printf '%s' "$out" | grep -q 'status 4' || { echo "check-verify: logged command failure was masked"; exit 1; }
run_logged sh -c 'echo init-passed' >/dev/null
echo "check-verify: ok"
