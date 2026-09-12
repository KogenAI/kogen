"""Collect only exact requested children; raw rollouts stay in ignored run storage."""
from pathlib import Path
import copy,hashlib,json,sys
run=Path(sys.argv[1]).resolve();sessions=Path(sys.argv[2]).resolve()
expected={"fresh_scout_route":("explorer","gpt-5.6-luna","low"),"fresh_worker_route":("worker","gpt-5.6-luna","medium"),"fresh_expert_route":("default","gpt-5.6-sol","medium")}
def rows(path): return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
index={}
for path in sessions.glob("*.jsonl"):
 try:
  with path.open() as f:meta=json.loads(next(f)).get("payload",{})
 except (OSError,ValueError,StopIteration):continue
 index[meta.get("id")]=(path,meta)
children={}
for identity,(path,meta) in index.items():
 name=meta.get("agent_path","").split("/")[-1]
 if name in expected:
  assert name not in children,"duplicate child name"
  children[name]=(path,meta)
assert set(children)==set(expected),"missing child"
parents={meta["parent_thread_id"] for path,meta in children.values()};assert len(parents)==1
parent_id=parents.pop();parent_path,parent_meta=index[parent_id]
parent_bytes=parent_path.read_bytes();(run/"raw/parent-at-collection.jsonl").write_bytes(parent_bytes)
parent_rows=[json.loads(x) for x in parent_bytes.splitlines() if x.strip()]
calls={}
for row in parent_rows:
 x=row.get("payload",{})
 if row.get("type")=="response_item" and x.get("type")=="function_call" and x.get("name")=="spawn_agent":
  a=json.loads(x["arguments"])
  if a.get("task_name") in expected: calls[a["task_name"]]=a
contexts=[x["payload"] for x in parent_rows if x.get("type")=="turn_context"]
receipt={"parent_id":parent_id,"parent_profile":{"model":contexts[-1].get("model"),"effort":contexts[-1].get("effort")},"parent_snapshot_sha256":hashlib.sha256(parent_bytes).hexdigest(),"children":[]}
for name,(path,meta) in sorted(children.items()):
 data=path.read_bytes();(run/"raw"/(name+".jsonl")).write_bytes(data)
 rr=[json.loads(x) for x in data.splitlines() if x.strip()];a=calls[name]
 profiles=sorted({(x["payload"].get("model"),x["payload"].get("effort")) for x in rr if x.get("type")=="turn_context"})
 complete=any(x.get("type")=="event_msg" and x.get("payload",{}).get("type")=="task_complete" for x in rr)
 answers=[x["payload"]["last_agent_message"] for x in rr if x.get("type")=="event_msg" and x.get("payload",{}).get("type")=="task_complete" and x["payload"].get("last_agent_message")]
 for x in rr:
  q=x.get("payload",{})
  if x.get("type")=="response_item" and q.get("type")=="message" and q.get("role")=="assistant" and q.get("channel")=="final":
   answers.extend(z.get("text","") for z in q.get("content",[]) if z.get("type")=="output_text")
 receipt["children"].append({"name":name,"parent_id":meta["parent_thread_id"],"child_id":meta["id"],"requested_kind":a.get("agent_type"),"requested_model":a.get("model"),"requested_effort":a.get("reasoning_effort"),"observed_profiles":[list(x) for x in profiles],"complete":complete,"source_sha256":hashlib.sha256(data).hexdigest(),"answer":"\n".join(answers)})
protocol=json.loads((run/"protocol.json").read_text())
receipt["fixture_unchanged"]=all(hashlib.sha256((run/"fixture"/name).read_bytes()).hexdigest()==digest for name,digest in protocol["fixture_sha256"].items())
def valid(r):
 if not r["fixture_unchanged"] or len(r["children"])!=3:return False
 if {c["name"] for c in r["children"]}!=set(expected):return False
 for c in r["children"]:
  kind,model,effort=expected[c["name"]]
  if (c["requested_kind"],c["requested_model"],c["requested_effort"])!=(kind,model,effort):return False
  if c["observed_profiles"]!=[[model,effort]] or c["parent_id"]!=r["parent_id"] or not c["complete"] or not c["answer"].strip():return False
 return True
assert valid(receipt),"native routing failed"
negatives={}
for name in ["missing-child","wrong-profile","unrelated-child","incomplete-child","changed-fixture","wrong-native-kind","missing-answer"]:
 bad=copy.deepcopy(receipt)
 if name=="missing-child":bad["children"].pop()
 elif name=="wrong-profile":bad["children"][0]["observed_profiles"]=[["wrong","low"]]
 elif name=="unrelated-child":bad["children"][0]["parent_id"]="another-parent"
 elif name=="incomplete-child":bad["children"][0]["complete"]=False
 elif name=="changed-fixture":bad["fixture_unchanged"]=False
 elif name=="wrong-native-kind":bad["children"][0]["requested_kind"]="expert"
 elif name=="missing-answer":bad["children"][0]["answer"]=""
 negatives[name]=not valid(bad)
assert all(negatives.values())
receipt["native_validation_passed"]=True;receipt["negative_controls_rejected"]=negatives
(run/"native-receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
print(json.dumps({"native_validation_passed":True,"parent_profile":receipt["parent_profile"],"child_profiles":{c["name"]:c["observed_profiles"] for c in receipt["children"]},"answers_captured":{c["name"]:bool(c["answer"]) for c in receipt["children"]},"fixture_unchanged":receipt["fixture_unchanged"],"negative_controls":negatives},indent=2))
