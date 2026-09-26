#!/usr/bin/env bash
# Probe 2: nesting a second sandbox-exec (a nested fixture Build wrapping its own roles).
set -u
P=/private/tmp/claude-501/kogen-prep5b/probe/p2
S=/private/tmp/claude-501/kogen-prep5b/probe/scripts
rm -rf "$P"; mkdir -p "$P/cand" "$P/home" "$P/tmp/inner-cand" "$P/tmp/inner-home" "$P/tmp/inner-tmp" "$P/outside"
PROFILE=/private/tmp/claude-501/kogen-prep5b/probe/wb.sb
sb() { sandbox-exec -f "$PROFILE" -D CANDIDATE="$P/cand" -D HARNESS_HOME="$P/home" -D TMP="$P/tmp" "$@"; }
run() { local name="$1"; shift; out=$("$@" 2>&1); echo "[$name] exit=$? ${out:+out=$(echo "$out"|tr '\n' ' '|cut -c1-160)}"; }
run nested-same-params           sb "$S/inner.sh" "$P/cand" "$P/home" "$P/tmp" sh -c "echo x > '$P/cand/same'"
run nested-narrower-inner-write  sb "$S/inner.sh" "$P/tmp/inner-cand" "$P/tmp/inner-home" "$P/tmp/inner-tmp" sh -c "echo x > '$P/tmp/inner-cand/a'"
run nested-narrower-outer-cand   sb "$S/inner.sh" "$P/tmp/inner-cand" "$P/tmp/inner-home" "$P/tmp/inner-tmp" sh -c "echo x > '$P/cand/escape'"
run nested-wider-param-outside   sb "$S/inner.sh" "$P/outside" "$P/tmp/inner-home" "$P/tmp/inner-tmp" sh -c "echo x > '$P/outside/a'"
run nested-allow-default-string  sb sandbox-exec -p '(version 1)(allow default)' true
run unsandboxed-string-control   sandbox-exec -p '(version 1)(allow default)' true
echo "outside: $(ls $P/outside|tr '\n' ' ') cand: $(ls $P/cand|tr '\n' ' ') inner: $(ls $P/tmp/inner-cand|tr '\n' ' ')"
