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
