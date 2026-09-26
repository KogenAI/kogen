#!/usr/bin/env bash
# Probe 7: `mix test` of Kogen's own suite files in a linked-worktree Candidate under the boundary,
# with the host PATH (mise on PATH, as a Developer's shell has it).
set -u
CONTROL=/private/tmp/claude-501/kogen-prep5b/kogen
P="/private/tmp/claude-501/kogen-prep5b/probe/p7 space"
rm -rf "$P"; mkdir -p "$P/home/tmp"
git -C "$CONTROL" worktree prune; git -C "$CONTROL" branch -D kogen/probe/p7 >/dev/null 2>&1
git -C "$CONTROL" worktree add -q -b kogen/probe/p7 "$P/cand" HEAD
cp -R "$CONTROL/deps" "$P/cand/deps"
PROFILE=/private/tmp/claude-501/kogen-prep5b/probe/wb.sb
MISE="$HOME/.local/share/mise/installs"
PATHX="$HOME/.local/bin:$MISE/elixir/1.20.2-otp-29/bin:$MISE/erlang/29.0.3/bin:/usr/bin:/bin:/usr/sbin:/sbin"
sb() { (cd "$P/cand" && env -i PATH="$PATHX" HOME="$HOME" USER="$USER" LOGNAME="$USER" LANG=en_US.UTF-8 TMPDIR="$P/home/tmp/" MIX_ENV=test \
  sandbox-exec -f "$PROFILE" -D CANDIDATE="$P/cand" -D HARNESS_HOME="$P/home" -D TMP="$P/home/tmp" "$@"); }
start=$(date '+%Y-%m-%d %H:%M:%S')
for f in test/kogen/verification_policy_test.exs test/kogen/harness_role_test.exs test/kogen/lifecycle_test.exs; do
  out=$(sb mix test "$f" 2>&1); ec=$?
  echo "[mix test $f] exit=$ec $(echo "$out" | grep -E '^[0-9]+ tests?,|Finished in' | tr '\n' ' ')"
  [ $ec -ne 0 ] && echo "$out" | grep -E 'Operation not permitted|eperm|:eacces|\*\* \(' | sort | uniq -c | head -8
done
sleep 2
echo "[sandbox denials since $start]"
log show --start "$start" --style compact --predicate 'eventMessage CONTAINS "deny(1) file-write"' 2>/dev/null | grep 'Sandbox:' | sed -E 's/^.*Sandbox: //; s/\([0-9]+\)//' | sed -E 's#/[0-9A-Za-z._-]{6,}$#/…#' | sort | uniq -c | head -40
git -C "$CONTROL" worktree remove --force "$P/cand"; git -C "$CONTROL" branch -D kogen/probe/p7 >/dev/null
