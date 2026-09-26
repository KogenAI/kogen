#!/usr/bin/env bash
# Probe 17: indirect escapes from inside the boundary: asking launchd to run a job (launchctl submit),
# LaunchServices (open), and a login-item style LaunchAgent plist. Each tries to create one file outside.
set -u
P=/private/tmp/claude-501/kogen-prep5b/probe/p17; rm -rf $P; mkdir -p $P/{c,h,t,outside}
PROFILE=${PROFILE:-/private/tmp/claude-501/kogen-prep5b/probe/wb.sb}
sb() { sandbox-exec -f "$PROFILE" -D CANDIDATE=$P/c -D HARNESS_HOME=$P/h -D TMP=$P/t "$@"; }
run() { local name="$1"; shift; out=$("$@" 2>&1); echo "[$name] exit=$? ${out:+out=$(echo "$out"|tr '\n' ' '|cut -c1-160)}"; }
printf '#!/bin/sh\necho escaped > %s/outside/$1\n' "$P" > $P/c/escape.sh; chmod +x $P/c/escape.sh
run launchctl-submit sb launchctl submit -l kogen.wb.probe.$$ -- $P/c/escape.sh launchctl
run launchagent-plist sb sh -c "cp /dev/null ~/Library/LaunchAgents/kogen.wb.probe.plist"
run open-command     sb open -a /System/Applications/Utilities/Terminal.app --args true
sleep 4
launchctl remove kogen.wb.probe.$$ 2>/dev/null
echo "[outside after] $(ls -A $P/outside | tr '\n' ' ')"
