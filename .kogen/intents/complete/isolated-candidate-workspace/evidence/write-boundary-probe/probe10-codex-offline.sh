#!/usr/bin/env bash
# Probe 10: managed Codex 0.156.1 under the write boundary without any provider call or credential:
# a disposable CODEX_HOME inside the harness home (no auth.json), and Codex's own Seatbelt nested inside ours.
set -u
P="/private/tmp/claude-501/kogen-prep5b/probe/p10 space"
rm -rf "$P"; mkdir -p "$P/cand" "$P/home/codex-home" "$P/home/op/home" "$P/home/tmp" "$P/outside"
git -C "$P/cand" init -q
PROFILE=/private/tmp/claude-501/kogen-prep5b/probe/wb.sb
CODEX="$HOME/Library/Application Support/Kogen/codex/runtimes/0.156.1-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
sb() { (cd "$P/cand" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$P/home/op/home" USER="$USER" LOGNAME="$USER" TERM=dumb \
  TMPDIR="$P/home/tmp/" CODEX_HOME="$P/home/codex-home" \
  sandbox-exec -f "$PROFILE" -D CANDIDATE="$P/cand" -D HARNESS_HOME="$P/home" -D TMP="$P/home/tmp" "$@"); }
run() { local name="$1"; shift; out=$("$@" 2>&1); ec=$?; echo "[$name] exit=$ec ${out:+out=$(echo "$out"|tail -4|tr '\n' ' '|cut -c1-260)}"; }
start=$(date '+%Y-%m-%d %H:%M:%S')
run version        sb "$CODEX" --version
run login-status   sb "$CODEX" -c 'cli_auth_credentials_store="file"' login status
run exec-no-auth   sb /usr/bin/perl -e 'alarm 45; exec @ARGV' "$CODEX" exec --skip-git-repo-check -c 'cli_auth_credentials_store="file"' -c 'check_for_update_on_startup=false' --dangerously-bypass-approvals-and-sandbox --json "reply ok" </dev/null
run own-seatbelt-nested sb "$CODEX" sandbox -- sh -c "echo x > '$P/cand/nested.txt'"
run own-seatbelt-unconfined-control env -i PATH=/usr/bin:/bin HOME="$P/home/op/home" CODEX_HOME="$P/home/codex-home" "$CODEX" sandbox -- sh -c "echo x > '$P/cand/unconfined.txt'"
sleep 2
echo "[codex-home] $(cd "$P/home/codex-home" && find . -maxdepth 2 | sort | tr '\n' ' ')"
echo "[cand] $(ls -A "$P/cand" | tr '\n' ' ')"
echo "[sandbox denials since $start]"
log show --start "$start" --style compact --predicate 'eventMessage CONTAINS "deny(1) file-write"' 2>/dev/null | grep 'Sandbox:' | sed -E 's/^.*Sandbox: //; s/\([0-9]+\)//' | sed -E 's#/[0-9A-Za-z._-]{6,}$#/…#' | sort | uniq -c | head -30
