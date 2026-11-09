# Sourced by real-use.sh. verify_project runs the project's verify_without_kogen so that its first
# failing command fails the check: a function called after `||` or in `if` would run with `set -e`
# switched off, and its last command alone would decide (call verify_project as a plain command).
verify_project() {
  set +e
  ( set -e; verify_without_kogen ) >> "$log" 2>&1
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "the project's own checks fail on the new commit (status $status)"
}

# Keep output visible for browser login, but use the command's status, not tee's status.
run_logged() {
  rm -f "$run_dir/command.status"
  (
    set +e
    "$@" 2>&1
    printf '%s\n' "$?" > "$run_dir/command.status"
  ) | tee -a "$log"
  status=$(cat "$run_dir/command.status")
  [ "$status" -eq 0 ] || fail "$* failed (status $status)"
}

# The engine writes start before the baseline checks and before it prints "building".
wait_for_build_start() (
  pid=$1 runs=$2 slug=$3 previous=$4 max_wait=$5
  deadline=$(( $(date +%s) + max_wait ))
  while kill -0 "$pid" 2>/dev/null; do
    for output in "$runs"/*/log.jsonl; do
      if [ -f "$output" ] && ! grep -Fxq "$output" "$previous" &&
         grep -F '"event":"start"' "$output" | grep -Fq "\"slug\":\"$slug\""; then
        exit 0
      fi
    done
    [ "$(date +%s)" -lt "$deadline" ] || exit 1
    sleep 1
  done
  exit 1
)

run_live_init() {
  if [ "$1" = kogen ]; then
    # Kogen's own Cucumber hooks need an archive even for the runner probe.
    KOGEN_ARCHIVE="$run_dir/kogen.tar.gz" run_logged kogen init
  else
    run_logged kogen init
  fi
}

# The card and reviewed files can quote the behaviour under test. They are
# retained as evidence and are still covered by the credential scan.
claude_route_outputs_clean() (
  matches=$(find "$run_dir" -maxdepth 1 -type f \
    ! -name request.md ! -name card.out ! -name reviewed-approval.txt ! -name reviewed-result.txt \
    -exec sh -c 'grep -IlF "provider login chatgpt" "$@"; [ "$?" -le 1 ]' sh {} +) || exit 1
  [ -z "$matches" ]
)
