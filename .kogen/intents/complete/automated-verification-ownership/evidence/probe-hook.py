import json,sys,pathlib
x=json.load(sys.stdin)
with open("hook-inputs.jsonl","a") as f: f.write(json.dumps(x)+"\n")
if x.get("hook_event_name")=="PreToolUse":
 print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Kogen probe: gate command blocked before execution. Do not retry."}}))
