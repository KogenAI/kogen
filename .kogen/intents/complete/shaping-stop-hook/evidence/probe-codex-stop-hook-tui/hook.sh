#!/bin/sh
# Probe Stop hook: logs its payload; blocks once after ONE (fresh) and once after FOUR (resume).
P=/private/tmp/claude-501/-Users-almirsarajcic-Areas-Kogen-kogen/e3f094ff-2fa9-429c-a66b-e6608d653666/scratchpad/sq3/probe/stophook
n=$(ls "$P/log" | wc -l | tr -d ' ')
payload=$(cat)
printf '%s\n' "$payload" > "$P/log/stop-$(printf %02d "$n").json"
msg=$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("last_assistant_message") or "").strip())')
active=$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("stop_hook_active"))')
case "$msg" in
  *ONE*) [ "$active" = "True" ] || { printf '%s' '{"decision":"block","reason":"PROBE BLOCK: reply with exactly the word TWO and end your turn."}'; exit 0; } ;;
  *FOUR*) [ "$active" = "True" ] || { printf '%s' '{"decision":"block","reason":"PROBE BLOCK: reply with exactly the word FIVE and end your turn."}'; exit 0; } ;;
esac
printf '%s' '{"continue":true}'
