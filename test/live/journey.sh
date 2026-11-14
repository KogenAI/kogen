# Journey stages and conclusion for real-use.sh (POSIX sh). Sourced after run_dir, say and fail exist.
#
#   journey_begin                          start the clock and an empty $run_dir/journey.tsv
#   journey_stage <name> <ok|failed|skipped>
#                                          append <utc>\t<name>\t<status>\t<elapsed seconds>
#   journey_conclude <start-commit> <final-file>
#                                          succeed only when every stage of JOURNEY_STAGES has a recorded ok
#                                          and the final commit is real; otherwise fail with the first cause.
#
# Nothing here retries: the first failure's cause stays in the transcript.
JOURNEY_STAGES=${JOURNEY_STAGES:-"shape approve build verify review commit"}

journey_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

journey_begin() {
  JOURNEY_START=$(date +%s)
  : > "$run_dir/journey.tsv"
}

journey_elapsed() { echo $(( $(date +%s) - ${JOURNEY_START:-$(date +%s)} )); }

journey_stage() {
  case "${2:-}" in
    ok|failed|skipped) ;;
    *) fail "journey: stage status must be ok, failed or skipped, not '${2:-}'" ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$(journey_now)" "$1" "$2" "$(journey_elapsed)" >> "$run_dir/journey.tsv"
}

# The last recorded status of a stage, or "missing".
journey_status() {
  status=$(awk -F '\t' -v n="$1" '$2 == n { s = $3 } END { if (s == "") s = "missing"; print s }' "$run_dir/journey.tsv" 2>/dev/null) || status=missing
  [ -n "$status" ] || status=missing
  printf '%s\n' "$status"
}

journey_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

journey_conclude() {
  start=$1 file=$2
  for name in $JOURNEY_STAGES; do
    status=$(journey_status "$name")
    [ "$status" = ok ] || fail "journey: stage $name $status"
  done
  final=$(git rev-parse HEAD)
  [ "$final" != "$start" ] || fail "journey: no new final commit"
  git log -1 --format=%b | grep -Fxq "Kogen-Intent: $SLUG" || fail "journey: final commit lacks Kogen-Intent: $SLUG"
  git cat-file -e "HEAD:$file" 2>/dev/null || fail "journey: final commit lacks $file"
  {
    printf 'journey result\n\nstage\tstatus\telapsed seconds\n'
    for name in $JOURNEY_STAGES; do
      awk -F '\t' -v n="$name" '$2 == n { l = $2 "\t" $3 "\t" $4 } END { print l }' "$run_dir/journey.tsv"
    done
    if [ -f "$run_dir/kogen.tar.gz" ]; then archive=$(journey_sha256 "$run_dir/kogen.tar.gz"); else archive="not available"; fi
    printf '\narchive sha256: %s\n' "$archive"
    printf 'platform: %s-%s\n' "$(uname -s)" "$(uname -m)"
    printf 'route: %s\n' "${route:-unknown}"
    printf 'source revision: %s\n' "${STUDIO_REVISION:-$start}"
    [ -z "${KOGEN_STUDIO_CORPUS_UPDATE:-}" ] || printf 'corpus update: %s\n' "$KOGEN_STUDIO_CORPUS_UPDATE"
    printf 'elapsed seconds: %s\n' "$(journey_elapsed)"
    printf 'final commit: %s\n' "$final"
  } > "$run_dir/journey-result.txt"
  say "journey: complete $final"
}
