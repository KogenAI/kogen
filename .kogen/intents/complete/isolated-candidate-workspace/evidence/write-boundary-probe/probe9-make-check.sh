#!/usr/bin/env bash
# Probe 9: the whole `make check` of Kogen at 363c20af in a linked-worktree Candidate, once without
# and once inside the write boundary (a Developer running the suite in its own shell).
set -u
P=/private/tmp/claude-501/kogen-prep5b/probe
D="$P/p7b space"; MISE="$HOME/.local/share/mise/installs"
PATHX="$HOME/.local/bin:$MISE/elixir/1.20.2-otp-29/bin:$MISE/erlang/29.0.3/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$D/cand"
for mode in plain sb; do
  if [ $mode = plain ]; then pre=(); else pre=(sandbox-exec -f $P/wb.sb -D CANDIDATE="$D/cand" -D HARNESS_HOME="$D/home" -D TMP="$D/home/tmp"); fi
  s=$(date +%s); start=$(date '+%Y-%m-%d %H:%M:%S')
  env -i PATH="$PATHX" HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh LANG=en_US.UTF-8 TMPDIR="$D/home/tmp/" "${pre[@]}" make check > "$P/probe9-$mode.log" 2>&1
  echo "$mode make check exit=$? seconds=$(( $(date +%s) - s ))"
  grep -E '^Result:|tests?, [0-9]+ failures?' "$P/probe9-$mode.log" | tail -3
  if [ $mode = sb ]; then
    log show --start "$start" --style compact --predicate 'eventMessage CONTAINS "deny(1) file-write"' 2>/dev/null | grep 'Sandbox:' | sed -E 's/^.*Sandbox: //; s/\([0-9]+\)//' | sed -E 's#/[0-9A-Za-z._-]{6,}$#/…#' | sort | uniq -c | sort -rn | head -30
  fi
done
