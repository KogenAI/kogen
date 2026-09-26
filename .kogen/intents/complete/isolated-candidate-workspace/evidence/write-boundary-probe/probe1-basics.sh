#!/usr/bin/env bash
# Probe 1: Seatbelt (sandbox-exec) write boundary basics on this host.
set -u
P=/private/tmp/claude-501/kogen-prep5b/probe/p1
rm -rf "$P"; mkdir -p "$P/cand" "$P/home" "$P/tmp" "$P/outside"
PROFILE=/private/tmp/claude-501/kogen-prep5b/probe/wb.sb
sb() { sandbox-exec -f "$PROFILE" -D CANDIDATE="$P/cand" -D HARNESS_HOME="$P/home" -D TMP="$P/tmp" "$@"; }
run() { local name="$1"; shift; out=$("$@" 2>&1); echo "[$name] exit=$? ${out:+out=$(echo "$out"|tr '\n' ' '|cut -c1-160)}"; }
echo orig > "$P/outside/target"; echo mv > "$P/outside/mv"
run inside-write        sb sh -c "echo ok > '$P/cand/a'"
run home-write          sb sh -c "echo ok > '$P/home/a'"
run tmp-write           sb sh -c "echo ok > '$P/tmp/a'"
run outside-write       sb sh -c "echo bad > '$P/outside/b'"
run outside-python      sb python3 -c "open('$P/outside/c','w').write('x')"
printf 'all:\n\tsh -c "echo x > %s/outside/d"\n' "$P" > "$P/cand/Makefile"
run outside-make-grandchild sb make -s -C "$P/cand"
run outside-via-tmp-alias sb sh -c "echo x > '/tmp/claude-501/kogen-prep5b/probe/p1/outside/e'"
ln -s "$P/outside" "$P/cand/link"
run outside-via-symlink  sb sh -c "echo x > '$P/cand/link/f'"
run hardlink-create      sb ln "$P/outside/target" "$P/cand/hl"
run outside-rename-in    sb mv "$P/outside/mv" "$P/cand/mv"
run outside-unlink       sb rm -f "$P/outside/target"
run outside-chmod        sb chmod 600 "$P/outside/target"
run outside-touch        sb touch "$P/outside/target"
run outside-xattr        sb xattr -w k v "$P/outside/target"
run outside-mkdir        sb mkdir "$P/outside/dir"
run nested-sandbox-exec  sb sandbox-exec -f "$PROFILE" -D CANDIDATE="$P/cand" -D HARNESS_HOME="$P/home" -D TMP="$P/tmp" sh -c "echo n > '$P/cand/n'"
run nested-then-outside  sb sandbox-exec -p '(version 1)(allow default)' sh -c "echo n > '$P/outside/nested'"
run background-daemonized sb sh -c "(nohup sh -c 'sleep 1; echo x > $P/outside/bg' >/dev/null 2>&1 &) ; exit 0"
sleep 2
echo "outside after: $(ls "$P/outside" | tr '\n' ' ') target=$(cat "$P/outside/target")"
echo "cand after: $(ls "$P/cand" | tr '\n' ' ')"
