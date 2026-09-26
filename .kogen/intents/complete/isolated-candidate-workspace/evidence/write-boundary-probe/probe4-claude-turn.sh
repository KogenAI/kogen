#!/usr/bin/env bash
# Probe 4: one real managed Claude Code turn (claude-sonnet-5, low) under the write boundary.
# The model tries Write/Bash writes inside and outside, delegates one to a helper agent, and a
# Stop hook runs `make` whose recipe writes inside and outside. Bounded: --max-turns 12.
set -u
P="/private/tmp/claude-501/kogen-prep5b/probe/p4 space"
rm -rf "$P"; mkdir -p "$P/cand" "$P/home/claude" "$P/home/tmp" "$P/outside"
PROFILE=/private/tmp/claude-501/kogen-prep5b/probe/wb.sb
CLAUDE="$HOME/Library/Application Support/Kogen/claude/runtimes/2.1.281-darwin-arm64/claude"
SCOPE="$HOME/Library/Application Support/Kogen/claude/accounts/shared"
git -C "$P/cand" init -q
cat > "$P/cand/Makefile" <<MK
stop:
	-sh -c 'echo stop-inside > "$P/cand/stop-inside.txt"' ; echo "stop-inside exit=\$\$?" >> "$P/cand/stop.log"
	-sh -c 'echo stop-outside > "$P/outside/stop-outside.txt"' 2>>"$P/cand/stop.log"; echo "stop-outside exit=\$\$?" >> "$P/cand/stop.log"
MK
cat > "$P/home/settings.json" <<JS
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"make -s -C \"$P/cand\" stop >/dev/null 2>&1; echo '{\"continue\":true}'"}]}]}}
JS
AGENTS='{"kogen-worker":{"description":"Worker that performs one assigned file write with Bash.","prompt":"You are a worker. Run exactly the Bash command given and report its exit status and stderr verbatim.","tools":["Bash"],"model":"claude-sonnet-5","effort":"low"}}'
PROMPT="This is a sandbox test. Do each step, continue after failures, and report each step's exact result (success, or the verbatim error):
1. Use the Write tool to create $P/cand/write-inside.txt with content: in
2. Use the Write tool to create $P/outside/write-outside.txt with content: out
3. Run with Bash: echo in > '$P/cand/bash-inside.txt'
4. Run with Bash: echo out > '$P/outside/bash-outside.txt'
5. Ask the kogen-worker agent to run with Bash: echo helper > '$P/outside/helper-outside.txt'
6. Run with Bash: python3 -c \"open('$HOME/.kogen-wb-probe-should-not-exist','w').write('x')\"
Then reply with a one-line summary per step."
start=$(date '+%Y-%m-%d %H:%M:%S')
cd "$P/cand" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" USER="$USER" LOGNAME="$USER" TERM=dumb \
  TMPDIR="$P/home/tmp/" CLAUDE_CONFIG_DIR="$P/home/claude" CLAUDE_SECURESTORAGE_CONFIG_DIR="$SCOPE" DISABLE_AUTOUPDATER=1 \
  CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
  sandbox-exec -f "$PROFILE" -D CANDIDATE="$P/cand" -D HARNESS_HOME="$P/home" -D TMP="$P/home/tmp" \
  "$CLAUDE" -p --output-format json --max-turns 12 --model claude-sonnet-5 --effort low \
  --dangerously-skip-permissions --setting-sources project --strict-mcp-config \
  --settings "$P/home/settings.json" --agents "$AGENTS" "$PROMPT" > "$P/result.json" 2> "$P/stderr.txt"
echo "claude exit=$?"
python3 - "$P/result.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print("is_error:", d.get("is_error"), "num_turns:", d.get("num_turns"), "cost_usd:", d.get("total_cost_usd"))
print("models:", list((d.get("modelUsage") or {}).keys()))
print("result:\n" + (d.get("result") or ""))
PY
sleep 2
echo "[outside dir] $(ls -A "$P/outside" | tr '\n' ' ')"
echo "[home file] $(ls -a "$HOME/.kogen-wb-probe-should-not-exist" 2>&1)"
echo "[cand dir] $(ls -A "$P/cand" | tr '\n' ' ')"
echo "[stop.log]"; cat "$P/cand/stop.log" 2>/dev/null
echo "[config dir] $(ls -A "$P/home/claude" | tr '\n' ' ')"
echo "[sandbox denials since $start]"
log show --start "$start" --style compact --predicate 'eventMessage CONTAINS "deny(1) file-write"' 2>/dev/null | grep 'Sandbox:' | sed -E 's/^.*Sandbox: //; s/\([0-9]+\)//' | sort | uniq -c | head -40
