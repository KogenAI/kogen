#!/usr/bin/env bash
# Probe 12: can a process inside the boundary update a login-keychain item (what a Claude Code OAuth
# refresh does through /usr/bin/security)? Uses a throwaway item, deleted afterwards. No credential read.
set -u
P=/private/tmp/claude-501/kogen-prep5b/probe/p12; rm -rf $P; mkdir -p $P/{c,h,t}
PROFILE=/private/tmp/claude-501/kogen-prep5b/probe/wb.sb
sb() { sandbox-exec -f "$PROFILE" -D CANDIDATE=$P/c -D HARNESS_HOME=$P/h -D TMP=$P/t "$@"; }
start=$(date '+%Y-%m-%d %H:%M:%S')
sb /usr/bin/security add-generic-password -U -a "$USER" -s kogen-write-boundary-probe -w probe-value-1 >/dev/null 2>&1; echo "[add inside boundary] exit=$?"
sb /usr/bin/security add-generic-password -U -a "$USER" -s kogen-write-boundary-probe -w probe-value-2 >/dev/null 2>&1; echo "[update inside boundary] exit=$?"
/usr/bin/security find-generic-password -a "$USER" -s kogen-write-boundary-probe >/dev/null 2>&1; echo "[item exists, checked outside] exit=$?"
/usr/bin/security delete-generic-password -a "$USER" -s kogen-write-boundary-probe >/dev/null 2>&1; echo "[cleanup delete outside] exit=$?"
sleep 1
log show --start "$start" --style compact --predicate 'eventMessage CONTAINS "deny(1) file-write"' 2>/dev/null | grep 'Sandbox:' | sed -E 's/^.*Sandbox: //; s/\([0-9]+\)//' | sort | uniq -c | head
