#!/usr/bin/env bash
# Probe 3: managed Claude Code 2.1.281 under the write boundary, no model call.
set -u
P="/private/tmp/claude-501/kogen-prep5b/probe/p3 space"
rm -rf "$P"; mkdir -p "$P/cand" "$P/home/claude" "$P/home/tmp" "$P/outside"
PROFILE=/private/tmp/claude-501/kogen-prep5b/probe/wb.sb
CLAUDE="$HOME/Library/Application Support/Kogen/claude/runtimes/2.1.281-darwin-arm64/claude"
SCOPE="$HOME/Library/Application Support/Kogen/claude/accounts/shared"
git -C "$P/cand" init -q
sb() { (cd "$P/cand" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" USER="$USER" LOGNAME="$USER" TERM=dumb \
  TMPDIR="$P/home/tmp/" CLAUDE_CONFIG_DIR="$P/home/claude" CLAUDE_SECURESTORAGE_CONFIG_DIR="$SCOPE" DISABLE_AUTOUPDATER=1 \
  sandbox-exec -f "$PROFILE" -D CANDIDATE="$P/cand" -D HARNESS_HOME="$P/home" -D TMP="$P/home/tmp" "$@"); }
start=$(date '+%Y-%m-%d %H:%M:%S')
echo "[version] $(sb "$CLAUDE" --version 2>&1 | tr '\n' ' ') exit=${PIPESTATUS[0]}"
out=$(sb "$CLAUDE" auth status 2>&1); echo "[auth-status] exit=$? loggedIn=$(echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("loggedIn"), d.get("authMethod"))' 2>/dev/null || echo "$out" | head -3)"
sleep 2
echo "[sandbox denials since $start]"
log show --start "$start" --style compact --predicate 'eventMessage CONTAINS "deny(1) file-write"' 2>/dev/null | grep -v '^Timestamp' | sed -E 's/^.*Sandbox: //' | sort | uniq -c | head -40
echo "[config dir]"; ls -A "$P/home/claude"
