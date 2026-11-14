#!/bin/sh
# Deterministic negative tests of journey.sh and projects/studio.sh: no model, no network. A journey
# concludes only when every stage and the final commit are real.
here=$(cd "$(dirname "$0")" && pwd)
bad() { echo "check-journey: $*"; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null"

# conclude <stages> <commit mode> prints the conclusion's output and leaves its exit code in $code.
n=0
conclude() {
  n=$((n + 1))
  dir="$work/case$n"; mkdir -p "$dir/project" "$dir/run"
  (
    cd "$dir/project"
    git init -q
    $git commit -q --allow-empty -m base
    start=$(git rev-parse HEAD)
    if [ "$2" != none ]; then
      if [ "$2" != no-file ]; then mkdir -p lib && echo x > lib/probe.ex && git add -A; fi
      if [ "$2" = no-trailer ]; then body='Kogen-Intent: other'; else body='Kogen-Intent: probe'; fi
      $git commit -q --allow-empty -m Title -m "$body"
    fi
    run_dir="$dir/run"; SLUG=probe
    say() { echo "$*"; }
    fail() { echo "FAIL: $*"; exit 1; }
    . "$here/journey.sh"
    journey_begin
    for s in $1; do journey_stage "${s%%=*}" "${s#*=}"; done
    journey_conclude "$start" lib/probe.ex
  ) > "$dir/out" 2>&1
  code=$?
  out=$(cat "$dir/out")
}
expect() { # <code> <text> <stages> <commit mode>
  conclude "$3" "$4"
  [ "$code" -eq "$1" ] || bad "[$3 / $4] exit $code, expected $1: $out"
  printf '%s' "$out" | grep -qF "$2" || bad "[$3 / $4] lacks \"$2\": $out"
}

all='shape=ok approve=ok build=ok verify=ok review=ok commit=ok'
expect 0 'journey: complete' "$all" good
expect 1 'journey: stage review missing' 'shape=ok approve=ok build=ok verify=ok commit=ok' good
expect 1 'journey: stage shape missing' '' good
expect 1 'journey: stage verify skipped' 'shape=ok approve=ok build=ok verify=skipped review=ok commit=ok' good
expect 1 'journey: stage build failed' 'shape=ok approve=ok build=failed verify=ok review=ok commit=ok' good
# The first offending stage in stage order is the one named.
expect 1 'journey: stage approve failed' 'shape=ok approve=failed build=ok verify=skipped review=ok commit=ok' good
expect 1 'journey: no new final commit' "$all" none
expect 1 'journey: final commit lacks Kogen-Intent: probe' "$all" no-trailer
expect 1 'journey: final commit lacks lib/probe.ex' "$all" no-file
# A stage the journey does not name is not required; JOURNEY_STAGES names the required ones.
(JOURNEY_STAGES='shape commit'; export JOURNEY_STAGES; expect 0 'journey: complete' 'shape=ok commit=ok' good) || exit 1
# A stage that failed and was later recorded ok is judged by its last record; a conclusion before any ok fails.
expect 1 'journey: stage build failed' 'shape=ok approve=ok build=ok build=failed verify=ok review=ok commit=ok' good

# An unknown stage status is refused.
conclude 'shape=maybe' good
[ "$code" -ne 0 ] && printf '%s' "$out" | grep -qF 'journey: stage status must be' || bad "an unknown status was accepted: $out"

# The record format and the result file.
conclude "$all" good
dir="$work/case$n"
[ "$(wc -l < "$dir/run/journey.tsv" | tr -d ' ')" = 6 ] || bad "journey.tsv does not hold six rows"
awk -F '\t' 'NF != 4 || $1 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$/ || $4 !~ /^[0-9]+$/ { exit 1 }' "$dir/run/journey.tsv" || bad "journey.tsv rows are not <utc> <name> <status> <seconds>"
sha=$(git -C "$dir/project" rev-parse HEAD)
for want in "shape	ok" "commit	ok" "archive sha256:" "platform: $(uname -s)-$(uname -m)" "route:" "source revision:" "elapsed seconds:" "final commit: $sha"; do
  grep -qF "$want" "$dir/run/journey-result.txt" || bad "journey-result.txt lacks \"$want\""
done
printf '%s' "$out" | grep -qF "journey: complete $sha" || bad "the conclusion does not name the final commit: $out"
# A failed conclusion writes no result.
conclude "$all" none
[ ! -e "$work/case$n/run/journey-result.txt" ] || bad "a failed journey wrote a result"

# Studio settings: the frozen revision, the override guard, the blocked results.
studio() { # <env assignments> <script>; prints output, leaves the exit code in $code
  run="$work/studio-run-$n"; n=$((n + 1)); mkdir -p "$run"
  out=$(env KOGEN_LIVE_RUN_DIR="$run" $1 sh -c "here=$here; . $here/projects/studio.sh || exit 1; $2" 2>&1); code=$?
}
studio '' 'echo "$STUDIO_REVISION $SLUG"'
[ "$code" -eq 0 ] && [ "$out" = 'b93ff1d6c0748d74ee410615ed07cafbb7de1f07 normalize-label-probe' ] || bad "the Studio settings do not pin the frozen task: $out"
studio 'KOGEN_STUDIO_REVISION=0123456789abcdef0123456789abcdef01234567' 'echo sourced'
[ "$code" -eq 1 ] && [ "$out" = 'studio: revision override needs KOGEN_STUDIO_CORPUS_UPDATE' ] || bad "an unrecorded revision override was accepted: $out"
studio 'KOGEN_STUDIO_REVISION=0123456789abcdef0123456789abcdef01234567 KOGEN_STUDIO_CORPUS_UPDATE=update-1' 'echo "$STUDIO_REVISION"'
[ "$code" -eq 0 ] && [ "$out" = 0123456789abcdef0123456789abcdef01234567 ] || bad "a recorded revision override was refused: $out"

studio 'KOGEN_STUDIO_URL=/nonexistent/studio.git' 'prepare_repo'
[ "$code" -ne 0 ] && printf '%s' "$out" | grep -qF 'studio: blocked:' || bad "an unreadable source was not blocked: $out"
[ ! -e "$work/studio-run-$((n - 1))/studio-origin" ] || bad "a blocked source left a repository"

source="$work/source"; mkdir "$source"
(cd "$source" && git init -q && $git commit -q --allow-empty -m one && echo 1 > f && git add f && $git commit -q -m two)
rev=$(git -C "$source" rev-parse HEAD~1)
studio "KOGEN_STUDIO_URL=$source KOGEN_STUDIO_REVISION=0000000000000000000000000000000000000000 KOGEN_STUDIO_CORPUS_UPDATE=test" 'prepare_repo'
[ "$code" -ne 0 ] && printf '%s' "$out" | grep -qF 'studio: blocked:' || bad "an absent commit was not blocked: $out"
studio "KOGEN_STUDIO_URL=$source KOGEN_STUDIO_REVISION=$rev KOGEN_STUDIO_CORPUS_UPDATE=test" 'prepare_repo && git -C "$REPO" rev-parse HEAD && git -C "$REPO" symbolic-ref -q HEAD'
[ "$code" -eq 0 ] && printf '%s' "$out" | grep -qxF "$rev" || bad "the frozen commit was not checked out: $out"
[ -z "$(git -C "$work/studio-run-$((n - 1))/studio-origin" status --porcelain)" ] || bad "the clone is not clean"
studio "KOGEN_STUDIO_URL=$source KOGEN_STUDIO_REVISION=$rev KOGEN_STUDIO_CORPUS_UPDATE=test" 'prepare_repo; prepare_repo'
[ "$code" -ne 0 ] && printf '%s' "$out" | grep -qF 'studio: blocked:' || bad "an existing repository was reused: $out"
echo "check-journey: ok"
