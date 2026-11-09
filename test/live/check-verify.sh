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

kogen() { printf '%s|%s\n' "$*" "${KOGEN_ARCHIVE:-}"; }
(
  unset KOGEN_ARCHIVE
  out=$(run_live_init kogen)
  [ "$out" = "init|$run_dir/kogen.tar.gz" ] || fail "self init lacks the installed archive"
  out=$(run_live_init example)
  [ "$out" = 'init|' ] || fail "self init leaked its archive to the example"
) || exit 1

sleep 10 &
child=$!
mkdir -p "$run_dir/runs/active" "$run_dir/runs/old"
previous="$run_dir/previous-build-runs.txt"
printf '%s\n' "$run_dir/runs/old/log.jsonl" > "$previous"
printf '%s\n' '{"event":"start","slug":"target"}' > "$run_dir/runs/old/log.jsonl"
printf '%s\n' '{"event":"start","slug":"another-task"}' > "$run_dir/runs/active/log.jsonl"
if wait_for_build_start "$child" "$run_dir/runs" target "$previous" 0; then
  kill "$child"
  fail "a stale or different Build was accepted"
fi
printf '%s\n' '{"event":"start","slug":"target"}' >> "$run_dir/runs/active/log.jsonl"
wait_for_build_start "$child" "$run_dir/runs" target "$previous" 1 || {
  kill "$child"
  fail "the engine start event was missed before baseline checks"
}
kill "$child"
wait "$child" 2>/dev/null || :

(
  export KOGEN_LIVE_RUN_DIR="$run_dir/example-fixture" GIT_CONFIG_GLOBAL="$run_dir/host-git-config"
  git config --file "$GIT_CONFIG_GLOBAL" user.name 'Release test identity'
  . "$here/projects/example.sh"
  [ "$(git config --get user.name)" = 'Release test identity' ] || fail "example replaced the host Git identity"
  [ "$(git -C "$REPO" log -1 --format=%an)" = 'Kogen Example' ] || fail "example baseline identity changed"
)
(
  run_dir="$run_dir/route"
  mkdir "$run_dir"
  printf '%s\n' 'Expected help: kogen provider login chatgpt' > "$run_dir/card.out"
  cp "$run_dir/card.out" "$run_dir/reviewed-result.txt"
  printf '%s\n' 'route: claude-code' > "$run_dir/transcript.txt"
  claude_route_outputs_clean || fail "approval evidence was mistaken for a runtime hint"
  printf '%s\n' 'Next: kogen provider login chatgpt' > "$run_dir/provider-list.out"
  if claude_route_outputs_clean; then fail "an actual runtime hint was missed"; fi
)
echo "check-verify: ok"
