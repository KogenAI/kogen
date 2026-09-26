#!/usr/bin/env bash
# inner.sh CAND HOME TMP cmd... : apply the write-boundary profile again (a nested Build's role launch)
PROFILE=/private/tmp/claude-501/kogen-prep5b/probe/wb.sb
exec sandbox-exec -f "$PROFILE" -D CANDIDATE="$1" -D HARNESS_HOME="$2" -D TMP="$3" "${@:4}"
