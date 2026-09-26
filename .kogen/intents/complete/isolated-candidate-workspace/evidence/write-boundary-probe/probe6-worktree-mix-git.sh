#!/usr/bin/env bash
# Probe 6: a real linked worktree of a Kogen clone as the Candidate; git and mix under the boundary.
set -u
CONTROL=/private/tmp/claude-501/kogen-prep5b/kogen
P="/private/tmp/claude-501/kogen-prep5b/probe/p6 space"
rm -rf "$P"; mkdir -p "$P/home/tmp"
git -C "$CONTROL" worktree prune
git -C "$CONTROL" branch -D kogen/probe/p6 >/dev/null 2>&1
git -C "$CONTROL" worktree add -q -b kogen/probe/p6 "$P/cand" HEAD
cp -R "$CONTROL/deps" "$P/cand/deps"
PROFILE=/private/tmp/claude-501/kogen-prep5b/probe/wb.sb
MISE="$HOME/.local/share/mise/installs"
PATHX="$MISE/elixir/1.20.2-otp-29/bin:$MISE/erlang/29.0.3/bin:/usr/bin:/bin:/usr/sbin:/sbin"
sb() { (cd "$P/cand" && env -i PATH="$PATHX" HOME="$HOME" USER="$USER" LOGNAME="$USER" LANG=en_US.UTF-8 TMPDIR="$P/home/tmp/" MIX_ENV=test \
  sandbox-exec -f "$PROFILE" -D CANDIDATE="$P/cand" -D HARNESS_HOME="$P/home" -D TMP="$P/home/tmp" "$@"); }
run() { local name="$1"; shift; out=$("$@" 2>&1); ec=$?; echo "[$name] exit=$ec ${out:+out=$(echo "$out"|tail -3|tr '\n' ' '|cut -c1-220)}"; }
start=$(date '+%Y-%m-%d %H:%M:%S')
echo "control gitdir: $(git -C "$P/cand" rev-parse --git-dir)"
run git-status        sb git status --porcelain
run git-diff          sb git diff --stat
run edit-tracked      sb sh -c "echo '# probe' >> README.md"
run git-status-after  sb git status --porcelain
run git-add           sb git add README.md
run git-commit        sb git commit -qam probe
run git-stash         sb git stash
run git-checkout-b    sb git checkout -q -b kogen/probe/escape
run git-update-ref    sb git update-ref refs/heads/main HEAD
run git-config-write  sb git config core.probe 1
run control-file      sb sh -c "echo x >> '$CONTROL/README.md'"
run control-gitdir    sb sh -c "echo x > '$CONTROL/.git/probe'"
run mix-compile       sb mix compile
run mix-test-one      sb mix test test/kogen/verification_policy_test.exs
sleep 2
echo "control status: $(git -C "$CONTROL" status --porcelain | head -5 | tr '\n' ' ') main=$(git -C "$CONTROL" rev-parse --short main) branches=$(git -C "$CONTROL" branch --list 'kogen/probe/*' | tr '\n' ' ')"
echo "[sandbox denials since $start]"
log show --start "$start" --style compact --predicate 'eventMessage CONTAINS "deny(1) file-write"' 2>/dev/null | grep 'Sandbox:' | sed -E 's/^.*Sandbox: //; s/\([0-9]+\)//' | sed -E 's#/[0-9A-Za-z._-]{6,}$#/…#' | sort | uniq -c | head -40
git -C "$CONTROL" worktree remove --force "$P/cand"; git -C "$CONTROL" branch -D kogen/probe/p6 >/dev/null
