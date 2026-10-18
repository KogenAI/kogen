#!/bin/sh
# Release acceptance on a real project (REL-1), rerunnable; stops at the first failed check and
# prints a transcript with UTC times.
#
#   sh test/live/real-use.sh <project> <archive-url>
#
# <project> names test/live/projects/<project>.sh, or is the path of such a file kept elsewhere (the
# external acceptance check on other projects). It sets REPO, SLUG, REQUEST, configure(),
# verify_without_kogen() and optionally INTERRUPT_AFTER (seconds into the first Build, default 60).
# <archive-url> is the release archive for this platform (https:// or file://).
#
# Step 2 is the real browser login: it runs `kogen provider login chatgpt` and waits for the
# person at the browser. With KOGEN_LIVE_CREDENTIALS=<command> set, that command writes the
# credentials into the fresh HOME instead (for an unattended rerun by the implementer).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
project=$1 url=$2
case "$project" in
  */*) settings=$(cd "$(dirname "$project")" && pwd)/$(basename "$project"); project=$(basename "$project" .sh) ;;
  *) settings=$here/projects/$project.sh ;;
esac
. "$settings"
. "$here/checked.sh"
INTERRUPT_AFTER=${INTERRUPT_AFTER:-60}

run_dir=${KOGEN_LIVE_RUN_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/kogen-real-use-$project.XXXXXX")}
mkdir -p "$run_dir"
run_dir=$(cd "$run_dir" && pwd -P)
log="$run_dir/transcript.txt"
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$log"; }
fail() { say "FAIL: $*"; exit 1; }
check() { if eval "$1"; then say "ok: $2"; else fail "$2"; fi; }

# A fresh user HOME that keeps the host's own Git configuration (identity, hooks, signing).
real_home=$HOME
export HOME="$run_dir/home" KOGEN_NO_BROWSER=${KOGEN_NO_BROWSER:-0}
mkdir -p "$HOME"
[ -f "$real_home/.gitconfig" ] && printf '[include]\n\tpath = %s/.gitconfig\n' "$real_home" > "$HOME/.gitconfig"
[ -d "$real_home/.gnupg" ] && export GNUPGHOME="${GNUPGHOME:-$real_home/.gnupg}"
say "run folder $run_dir, project $project, archive $url, $(uname -s)-$(uname -m)"

# 1. Download, install, version from /.
curl -fsSL -o "$run_dir/kogen.tar.gz" "$url"
mkdir "$run_dir/archive" && tar -xzf "$run_dir/kogen.tar.gz" -C "$run_dir/archive"
run_logged sh "$run_dir"/archive/kogen-*/install.sh
export PATH="$HOME/.local/bin:$PATH"
check '(cd / && kogen version) >> "$log"' "kogen version works from /"

# 2. Login before init, which asks the model to configure an existing repository.
if [ -n "${KOGEN_LIVE_CREDENTIALS:-}" ]; then
  sh -c "$KOGEN_LIVE_CREDENTIALS" >> "$log"
  say "login: credentials written by KOGEN_LIVE_CREDENTIALS (unattended rerun; the browser login is the person's step)"
else
  run_logged kogen provider login chatgpt
fi
check 'kogen provider list | grep -q "^chatgpt: signed in"' "kogen provider list shows chatgpt: signed in"

# 3. Fresh clone, init, assert the selected commands, commit project-specific adjustments.
git clone -q "$REPO" "$run_dir/project"
cd "$run_dir/project"
start=$(git rev-parse HEAD)
run_logged kogen init
cat .kogen/project.yaml >> "$log"
configure
git add -A
if ! git diff --cached --quiet; then git commit -q -m "Configure Kogen"; fi
configured=$(git rev-parse HEAD)
say "configured: $(git log -1 --format='%h %s')"

# 4. Shape; answer any question with its recommended option.
printf '%s\n' "$REQUEST" > "$run_dir/request.md"
set +e
kogen intent shape "$SLUG" "$run_dir/request.md" > "$run_dir/shape.out" 2>> "$log"; code=$?
while [ $code -eq 5 ] && grep -q '^Questions for' "$run_dir/shape.out"; do
  cat "$run_dir/shape.out" >> "$log"
  awk '/^[0-9]+\. /{n=$1; sub(/\.$/,"",n)} /\(recommended\)/{l=$1; sub(/\)$/,"",l); print n": "l}' "$run_dir/shape.out" > "$run_dir/answers.txt"
  say "answering: $(tr '\n' ' ' < "$run_dir/answers.txt")"
  kogen intent shape "$SLUG" "$run_dir/answers.txt" > "$run_dir/shape.out" 2>> "$log"; code=$?
done
set -e
cat "$run_dir/shape.out" >> "$log"
[ $code -eq 0 ] || fail "shaping ended with exit $code"
check 'grep -q "fail now" "$run_dir/shape.out"' "the Intent is ready with its scenarios failing"

# 5. Read the Intent and step files, approve with the card's hash.
kogen intent approve "$SLUG" > "$run_dir/card.out" || [ $? -eq 5 ]
cat "$run_dir/card.out" >> "$log"
for f in $(sed -n '/^Files$/,/^Approve with:$/s/^  - //p' "$run_dir/card.out"); do
  printf '\n----- %s\n' "$f" >> "$log"; cat "$f" >> "$log"
done
hash=$(sed -n "s/^  kogen intent approve $SLUG //p" "$run_dir/card.out")
run_logged kogen intent approve "$SLUG" "$hash"

# 6. Build, interrupt it, discard the edits.
kogen intent build "$SLUG" > "$run_dir/build1.out" 2>> "$log" &
pid=$!
sleep "$INTERRUPT_AFTER"
kill -INT $pid
t0=$(date +%s)
set +e; wait $pid; code=$?; set -e
took=$(( $(date +%s) - t0 ))
cat "$run_dir/build1.out" >> "$log"
check '[ $code -eq 130 ] && [ $took -le 15 ]' "the interrupted Build exited 130 within 15 s (exit $code, ${took} s)"
check '[ "$(git rev-parse HEAD)" = "$configured" ]' "no new commit after the interrupt"
for f in $(sed -n 's/^  edited: //p' "$run_dir/build1.out" | tr ',' ' '); do
  if git cat-file -e "HEAD:$f" 2>/dev/null; then git checkout -q -- "$f"; else rm -rf "$f"; fi
done
say "discarded the listed edits"

# 7. Build again: tool calls run, the Build lands with review approved.
set +e; kogen intent build "$SLUG" > "$run_dir/build2.out" 2>> "$log"; code=$?; set -e
cat "$run_dir/build2.out" >> "$log"
[ $code -eq 0 ] || fail "the second Build ended with exit $code"
run=$(ls -t .kogen/local/runs | head -1)
check 'grep -q "\"event\":\"tool_call\"" .kogen/local/runs/$run/log.jsonl' "at least one tool call ran with the default configuration"
check 'grep -q "^  review: approved" "$run_dir/build2.out"' "the Build landed with review: approved"
if grep -q '"green":false' ".kogen/local/runs/$run/log.jsonl" || grep -q '"verdict":"changes"' ".kogen/local/runs/$run/log.jsonl"; then
  say "repair: yes (a failing pass or a changes review was repaired)"
else
  say "repair: no (the first pass was green and the first review approved)"
fi

# 8. Without Kogen: the project's own acceptance command and tests on the new commit.
new=$(git rev-parse HEAD)
say "new commit $new"
verify_project
say "ok: the project's own acceptance command and tests pass without Kogen"
title=$(sed -n '1s/^# //p' ".kogen/intents/$SLUG/intent.md")
check '[ "$(git log -1 --format=%s)" = "$title" ]' "commit subject is the Intent title"
check '[ "$(git log -1 --format=%b | grep -c .)" = 1 ] && git log -1 --format=%b | grep -qx "Kogen-Intent: $SLUG"' "the only trailer is Kogen-Intent: $SLUG"
check '! git log -1 --format=%B | grep -qiE "co-authored-by|generated with|claude|chatgpt|openai|codex"' "no AI attribution"
if [ "$(git config --get commit.gpgsign || true)" = "true" ]; then
  check 'git cat-file commit HEAD | grep -q "^gpgsig"' "signed, as this host's Git configuration says"
else
  check '! git cat-file commit HEAD | grep -q "^gpgsig"' "unsigned, as this host's Git configuration says"
fi
git show --stat --format='%H %s' HEAD >> "$log"
cat .kogen/local/runs/$run/review-*.json >> "$log"
say "read the saved review(s) above"

# 9. No Kogen process alive, no token anywhere.
check '! pgrep -f "$HOME/.local/lib/kogen" >/dev/null' "no Kogen process is alive"
python3 - "$HOME/.kogen/credentials/chatgpt.json" "$run_dir/project" "$run_dir" > "$run_dir/leak.txt" <<'EOF'
import json, os, sys
c = json.load(open(sys.argv[1]))
secrets = [c[k].encode() for k in ("access_token", "refresh_token") if c.get(k)]
paths = [os.path.join(sys.argv[3], f) for f in os.listdir(sys.argv[3]) if os.path.isfile(os.path.join(sys.argv[3], f))]
for p in paths:
    if any(s in open(p, "rb").read() for s in secrets):
        print(p)
for base, _, files in os.walk(sys.argv[2]):
    if "/.git" in base:
        continue
    for f in files:
        p = os.path.join(base, f)
        try:
            data = open(p, "rb").read()
        except OSError:
            continue
        if any(s in data for s in secrets):
            print(p)
EOF
check '[ ! -s "$run_dir/leak.txt" ]' "no credential token in the project, .kogen/local, the transcript or the command outputs"

# 10. Uninstall.
run_logged kogen uninstall
hash -r
check '! command -v kogen >/dev/null && [ ! -e "$HOME/.local/bin/kogen" ] && [ ! -e "$HOME/.local/lib/kogen" ]' "kogen is gone"
check '[ -f "$HOME/.kogen/credentials/chatgpt.json" ] && [ -f .kogen/project.yaml ] && [ "$(git rev-parse HEAD)" = "$new" ]' "the project and ~/.kogen are intact"
say "REL-1 passed for $project"
