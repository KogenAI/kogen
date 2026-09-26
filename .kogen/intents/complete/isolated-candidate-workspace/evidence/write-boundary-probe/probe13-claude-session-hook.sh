#!/usr/bin/env bash
# Probe 13: the paid-proof mechanism. A fixture project's own .claude/settings.json SessionStart hook
# (loaded through --setting-sources project) runs inside the real Claude Code process tree on a fresh
# turn and on an exact resume. It tries one write outside the Candidate (into the control checkout's
# ignored runtime dir) and one inside, and records both results in the retained-evidence dir.
set -u
P="/private/tmp/claude-501/kogen-prep5b/probe/p13 space"
rm -rf "$P"; mkdir -p "$P/control/.kogen/runtime" "$P/home/claude" "$P/buildtmp" "$P/evidence"
git -C "$P/control" init -q; printf '.kogen/runtime/\n' > "$P/control/.gitignore"
mkdir -p "$P/control/.claude"
cat > "$P/control/.claude/boundary_probe.sh" <<'SH'
#!/bin/sh
# Fixture-only SessionStart probe: runs inside the role's process tree.
[ -n "${KOGEN_BOUNDARY_PROBE_DIR:-}" ] || exit 0
top=$(git rev-parse --show-toplevel)
mkdir -p "$top/.kogen/runtime" 2>/dev/null
( echo in > "$top/.kogen/runtime/boundary-inside" ) 2>/dev/null; inside=$?
( echo out > "$KOGEN_BOUNDARY_PROBE_OUTSIDE/escape-$$" ) 2>/dev/null; outside=$?
printf '{"role":"%s","pid":%s,"cwd":"%s","inside_exit":%s,"outside_exit":%s}\n' "${KOGEN_ROLE:-}" "$$" "$top" "$inside" "$outside" >> "$KOGEN_BOUNDARY_PROBE_DIR/session-start.jsonl"
exit 0
SH
chmod +x "$P/control/.claude/boundary_probe.sh"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"sh \\"$(git rev-parse --show-toplevel)/.claude/boundary_probe.sh\\""}]}]}}\n' > "$P/control/.claude/settings.json"
git -C "$P/control" add -A; git -C "$P/control" -c user.email=p@p -c user.name=p commit -qm base
git -C "$P/control" worktree add -q -b cand "$P/cand"
CAND=$(cd "$P/cand" && pwd -P); HOMEH=$(cd "$P/home" && pwd -P); BT=$(cd "$P/buildtmp" && pwd -P); EV=$(cd "$P/evidence" && pwd -P)
CLAUDE="$HOME/Library/Application Support/Kogen/claude/runtimes/2.1.281-darwin-arm64/claude"
SCOPE="$HOME/Library/Application Support/Kogen/claude/accounts/shared"
sb() { (cd "$CAND" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" USER="$USER" LOGNAME="$USER" TERM=dumb \
  TMPDIR="$BT/" CLAUDE_CODE_TMPDIR="$BT" CLAUDE_CONFIG_DIR="$HOMEH/claude" CLAUDE_SECURESTORAGE_CONFIG_DIR="$SCOPE" \
  DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 KOGEN_ROLE=developer \
  KOGEN_BOUNDARY_PROBE_DIR="$EV" KOGEN_BOUNDARY_PROBE_OUTSIDE="$P/control/.kogen/runtime" \
  sandbox-exec -f /private/tmp/claude-501/kogen-prep5b/probe/wb-claude.sb -D CANDIDATE="$CAND" -D HARNESS_HOME="$HOMEH" \
  -D BUILD_TMP="$BT" -D RETAINED_EVIDENCE="$EV" -D CLAUDE_SCOPE="$SCOPE" -D LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db" \
  "$CLAUDE" -p --output-format json --max-turns 3 --model claude-sonnet-5 --effort low --dangerously-skip-permissions \
  --setting-sources project --strict-mcp-config "$@"); }
SID=$(python3 -c 'import uuid;print(uuid.uuid4())')
start=$(date '+%Y-%m-%d %H:%M:%S')
sb --session-id "$SID" "Reply with exactly: ok" > "$P/fresh.json" 2>"$P/fresh.err"; echo "[fresh] exit=$? $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("is_error"),d.get("result"),d.get("session_id"),d.get("total_cost_usd"))' "$P/fresh.json")"
sb --resume "$SID" "Reply with exactly: again" > "$P/resume.json" 2>"$P/resume.err"; echo "[resume] exit=$? $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("is_error"),d.get("result"),d.get("session_id"),d.get("total_cost_usd"))' "$P/resume.json")"
echo "[session-start receipts]"; cat "$EV/session-start.jsonl" 2>/dev/null
echo "[control runtime] $(ls -A "$P/control/.kogen/runtime" | tr '\n' ' ')"
echo "[candidate runtime] $(ls -A "$CAND/.kogen/runtime" 2>/dev/null | tr '\n' ' ')"
echo "[transcripts] $(cd "$HOMEH/claude/projects" && find . -name '*.jsonl' | tr '\n' ' ')"
sleep 2
echo "[sandbox denials since $start]"
log show --start "$start" --style compact --predicate 'eventMessage CONTAINS "deny(1) file-write"' 2>/dev/null | grep 'Sandbox:' | sed -E 's/^.*Sandbox: //; s/\([0-9]+\)//' | sort | uniq -c | head -20
