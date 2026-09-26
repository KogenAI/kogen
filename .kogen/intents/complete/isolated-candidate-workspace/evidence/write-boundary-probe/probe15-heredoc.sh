#!/usr/bin/env bash
# Probe 15: here-documents and process substitution in the user's login shell (zsh) and /bin/bash
# inside the boundary, with TMPDIR set to the Build temp dir, with and without zsh's TMPPREFIX.
set -u
P=/private/tmp/claude-501/kogen-prep5b/probe/p15; rm -rf $P; mkdir -p $P/{c,h,t}
sb() { sandbox-exec -f /private/tmp/claude-501/kogen-prep5b/probe/wb.sb -D CANDIDATE=$P/c -D HARNESS_HOME=$P/h -D TMP=$P/t "$@"; }
HD=$'cat <<EOF\nheredoc-ok\nEOF'
PS='cat <(echo procsub-ok)'
run() { local name="$1"; shift; out=$("$@" 2>&1); echo "[$name] exit=$? out=$(echo "$out" | tr '\n' ' ' | cut -c1-120)"; }
run zsh-heredoc-TMPDIR-only      sb env TMPDIR=$P/t/ zsh -f -c "$HD"
run zsh-heredoc-with-TMPPREFIX   sb env TMPDIR=$P/t/ TMPPREFIX=$P/t/zsh zsh -f -c "$HD"
run zsh-procsub-with-TMPPREFIX   sb env TMPDIR=$P/t/ TMPPREFIX=$P/t/zsh zsh -f -c "$PS"
run bash-heredoc-TMPDIR          sb env TMPDIR=$P/t/ /bin/bash -c "$HD"
run sh-heredoc-TMPDIR            sb env TMPDIR=$P/t/ /bin/sh -c "$HD"
