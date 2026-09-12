run = System.fetch_env!("KOGEN_PROBE_RUN")
shim = Path.join(run, "provider-shim")
File.write!(shim, """
#!/usr/bin/env python3
import json, os, sys
sys.stdin.read()
mode=os.environ['KOGEN_PROBE_MODE']
with open(os.environ['KOGEN_PROBE_CALLS'],'a') as f: f.write(mode+'\\n')
def emit(x):print(json.dumps(x))
if mode=='exit':
 print('requested profile unavailable');sys.exit(23)
emit({'type':'thread.started','thread_id':'boundary-probe'})
if mode=='provider-error':
 emit({'type':'error','message':'requested profile unavailable'});sys.exit(0)
if mode=='incomplete':sys.exit(0)
if mode=='malformed':emit({'type':'item.completed','item':{'type':'agent_message','text':'not JSON'}})
else:emit({'type':'item.completed','item':{'type':'agent_message','text':json.dumps({'candidate_id':'probe','attempt_token':'probe','verdict':'accept','scenarios':[],'dispositions':[],'findings':[]})}})
emit({'type':'turn.completed','usage':{'input_tokens':1,'output_tokens':1}})
""")
File.chmod!(shim, 0o755)
System.put_env("KOGEN_HARNESS", shim)
System.put_env("KOGEN_PROBE_CALLS", Path.join(run, "provider-calls.txt"))
results = Enum.map(["exit", "provider-error", "incomplete", "malformed", "valid"], fn mode ->
  System.put_env("KOGEN_PROBE_MODE", mode)
  developer = Kogen.Harness.launch_developer("offline probe", "requested-profile", "low")
  reviewer = Kogen.Harness.launch_reviewer("offline probe", "requested-profile", "low")
  %{mode: mode, developer: inspect(developer), reviewer: inspect(reviewer)}
end)
File.write!(Path.join(run, "provider-boundary.json"), Jason.encode!(results, pretty: true))
# This is a negative control against the actual unmodified engine, not a fix.
for result <- results, result.mode in ["exit", "provider-error", "incomplete"] do
  unless String.contains?(result.reviewer, "malformed_verdict"), do: raise("baseline defect changed")
end
unless String.contains?(Enum.find(results, &(&1.mode == "valid")).reviewer, "{:ok,"), do: raise("positive verdict failed")
unless String.contains?(Enum.find(results, &(&1.mode == "malformed")).reviewer, "malformed_verdict"), do: raise("malformed control failed")
IO.puts("Actual harness negative control reproduced provider-failure misclassification; completed valid/malformed verdict controls passed; no provider calls.")
