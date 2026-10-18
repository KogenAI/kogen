#!/bin/sh
# The rest of REL-3 after the installed Kogen landed a change in a disposable Kogen repository:
# the resulting source passes its deterministic suite with an isolated HOME and no real
# credentials, is packaged, installed into a separate prefix and the change is observed there.
#
#   sh test/live/self-build-check.sh <landed-project-dir>
#
# The observation matches the change test/live/projects/kogen.sh requests: `kogen provider list`
# on an unreadable saved login.
set -eu
project=$(cd "$1" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/kogen-self-check.XXXXXX")
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

cd "$project"
say "self-built source at $(git log -1 --format='%h %s')"
archive=$(sh packaging/package.sh 2>/dev/null | tail -1)
say "packaged $archive"

mkdir -p "$work/suite-home"
MIX_HOME="${MIX_HOME:-$HOME/.mix}" HEX_HOME="${HEX_HOME:-$HOME/.hex}" HOME="$work/suite-home" KOGEN_ARCHIVE="$archive" sh test/suite.sh > "$work/suite.out" 2>&1 || { tail -40 "$work/suite.out"; say "FAIL: the self-built deterministic suite"; exit 1; }
tail -4 "$work/suite.out"
say "ok: the self-built deterministic suite passes"

mkdir -p "$work/extract" "$work/home"
tar -xzf "$archive" -C "$work/extract"
(cd / && HOME="$work/home" sh "$work"/extract/kogen-*/install.sh --prefix "$work/prefix")
mkdir -p "$work/home/.kogen/credentials"
printf 'not json\n' > "$work/home/.kogen/credentials/chatgpt.json"
chmod 600 "$work/home/.kogen/credentials/chatgpt.json"
set +e
out=$(cd / && HOME="$work/home" "$work/prefix/bin/kogen" provider list 2>&1); code=$?
set -e
say "outside the checkout, kogen provider list with an unreadable login: exit $code: $out"
[ "$code" -eq 4 ] || { say "FAIL: expected provider/login exit 4"; exit 1; }
case "$out" in
  *provider/login:*cannot*read*) ;;
  *) say "FAIL: expected an actionable unreadable-login error"; exit 1 ;;
esac
case "$out" in
  *"kogen provider login chatgpt"*) ;;
  *) say "FAIL: the error does not explain how to sign in again"; exit 1 ;;
esac
say "ok: the change is observed in the installed self-built release"
