#!/usr/bin/env bash
# Probe 19 (real Codex, run only while ~/Areas/Kogen/kogen/.kogen/build.lock is absent, lesson 10):
# managed Codex 0.156.1 on the shared Kogen scope, launched the way Kogen launches a Codex role
# (private HOME/XDG and sqlite under a per-Build harness home, CODEX_HOME = scope, Kogen's
# --disable/--enable flags and the retained bypass flags) inside the Codex rendering of the boundary.
# One fresh exec turn and one exact resume on gpt-6-luna (low). The model runs shell commands that
# write inside the Candidate, into the harness home, and outside (the probe control checkout).
set -u
[ -e "$HOME/Areas/Kogen/kogen/.kogen/build.lock" ] && { echo "build.lock present; not running"; exit 3; }
P="/private/tmp/claude-501/kogen-prep5b/probe/p19 space"
rm -rf "$P"; mkdir -p "$P/control" "$P/home/codex/generation/home" "$P/home/codex/generation/xdg-config" "$P/home/codex/generation/xdg-data" "$P/home/codex/generation/xdg-cache" "$P/home/codex/generation/xdg-state" "$P/home/codex/state/sqlite" "$P/buildtmp"
git -C "$P/control" init -q; echo base > "$P/control/README.md"; git -C "$P/control" add -A; git -C "$P/control" -c user.email=p@p -c user.name=p commit -qm base
git -C "$P/control" worktree add -q -b cand "$P/cand"
CAND=$(cd "$P/cand" && pwd -P); HOMEH=$(cd "$P/home" && pwd -P); BT=$(cd "$P/buildtmp" && pwd -P); CONTROL=$(cd "$P/control" && pwd -P)
CODEX="$HOME/Library/Application Support/Kogen/codex/runtimes/0.156.1-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
SCOPE="$HOME/Library/Application Support/Kogen/codex/accounts/shared"
GEN="$HOMEH/codex/generation"
printf '#!/bin/sh\nexec "%s" exec-server --listen stdio\n' "$CODEX" > "$GEN/executor"; chmod +x "$GEN/executor"
before=$(cd "$SCOPE" && ls -A | sort | tr '\n' ' ')
sb() { (cd "$CAND" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin USER="$USER" LOGNAME="$USER" TERM=dumb LANG=en_US.UTF-8 \
  HOME="$GEN/home" XDG_CONFIG_HOME="$GEN/xdg-config" XDG_DATA_HOME="$GEN/xdg-data" XDG_CACHE_HOME="$GEN/xdg-cache" XDG_STATE_HOME="$GEN/xdg-state" \
  TMPDIR="$BT/" TMPPREFIX="$BT/zsh" CODEX_HOME="$SCOPE" SQLITE_HOME="$HOMEH/codex/state/sqlite" KOGEN_CODEX_EXECUTOR_ENTRYPOINT="$GEN/executor" \
  sandbox-exec -f /private/tmp/claude-501/kogen-prep5b/probe/wb-codex.sb.tmpl -D CANDIDATE="$CAND" -D HARNESS_HOME="$HOMEH" -D BUILD_TMP="$BT" \
  -D CODEX_SCOPE="$SCOPE" -D LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db" "$CODEX" "$@"); }
FLAGS=(--disable apps --disable plugins --disable shell_snapshot --enable hooks --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox
  -m gpt-6-luna -c 'model_reasoning_effort="low"' -c 'cli_auth_credentials_store="file"' -c 'check_for_update_on_startup=false'
  -c "projects.\"$CAND\".trust_level=\"trusted\"" -c "sqlite_home=\"$HOMEH/codex/state/sqlite\"" -c tool_output_token_limit=4000 --json)
start=$(date '+%Y-%m-%d %H:%M:%S')
echo "[login status] $(sb -c 'cli_auth_credentials_store="file"' login status 2>&1 | tail -1)"
PROMPT="Write-boundary test. Run each shell command separately, continue after failures, and report each command's exit status and stderr verbatim:
1. printf 'inside\n' > codex-inside.txt
2. printf 'home\n' > '$HOMEH/codex-home-write.txt'
3. printf 'out\n' > '$CONTROL/codex-outside.txt'
4. git -C '$CONTROL' update-ref refs/heads/escape HEAD
Reply with one line per command."
sb exec "${FLAGS[@]}" - <<<"$PROMPT" > "$P/fresh.jsonl" 2> "$P/fresh.err"; echo "[fresh] exit=$?"
TID=$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
  try: e=json.loads(l)
  except Exception: continue
  if e.get("type")=="thread.started": print(e.get("thread_id")); break' "$P/fresh.jsonl")
python3 - "$P/fresh.jsonl" <<'PY'
import json,sys
last=None
for l in open(sys.argv[1]):
    try: e=json.loads(l)
    except Exception: continue
    if e.get("type")=="item.completed" and (e.get("item") or {}).get("type") in ("agent_message","command_execution"):
        it=e["item"]; print("  ", it.get("type"), (it.get("command") or ""), "exit=", it.get("exit_code"), (it.get("aggregated_output") or it.get("text") or "").strip()[:200].replace("\n"," | "))
    if e.get("type") in ("turn.completed","turn.failed","error"): last=e.get("type")
print("   last event:", last)
PY
sb exec resume "${FLAGS[@]}" "$TID" - <<<"Reply with exactly: resumed" > "$P/resume.jsonl" 2> "$P/resume.err"; echo "[resume $TID] exit=$? $(grep -o '"text":"[^"]*"' "$P/resume.jsonl" | tail -1)"
sleep 2
after=$(cd "$SCOPE" && ls -A | sort | tr '\n' ' ')
echo "[scope top-level entries unchanged] $([ "$before" = "$after" ] && echo yes || echo "no: before=[$before] after=[$after]")"
echo "[control] files=$(ls -A "$CONTROL" | tr '\n' ' ') refs=$(git -C "$CONTROL" for-each-ref --format='%(refname)' | tr '\n' ' ')"
echo "[candidate] $(ls -A "$CAND" | tr '\n' ' ')"
echo "[harness home] $(ls -A "$HOMEH" | tr '\n' ' ')"
echo "[sandbox denials since $start]"
log show --start "$start" --style compact --predicate 'eventMessage CONTAINS "deny(1) file-write"' 2>/dev/null | grep 'Sandbox:' | sed -E 's/^.*Sandbox: //; s/\([0-9]+\)//' | sort | uniq -c | head -30
