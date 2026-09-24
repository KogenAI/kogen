import json, sys, random, concurrent.futures as cf
sys.path.insert(0, sys.argv[1]); import probe
import importlib.util
OUT=sys.argv[1]
spec=importlib.util.spec_from_file_location("pv2", OUT+"/prose_v2.py")
src=open(OUT+"/prose_v2.py").read().split("with cf.ThreadPoolExecutor")[0]
ns={"__name__":"pv2"}; sys.argv=[sys.argv[0],OUT]; exec(src,ns)
V2=json.load(open(OUT+"/prose-v2.json"))
OBJ={("1vg5QEsj",0),("2xt-TMNZ",1),("Bg1qobsC",1),("Bg1qobsC",2),("LUPXtmoI",1),("QpZjQahd",0),("VZFIeCIg",0),("_3Vw8Aoa",0),("hIhZhNA3",2),("dEkBAojD",2)}
def k(r): return (r["record"].split("/")[-2][:8],r["attempt"])
pos=[r for r in V2 if k(r) in OBJ or any(u for kind,i,u,o in r["items"] if kind=="scenario")]
neg=[r for r in V2 if r not in pos and not any(i=="reviewer-directed-rework" for kind,i,u,o in r["items"])]
random.seed(7); sample=pos+random.sample(neg,40)
# tricky synthetic set with v2 criteria
T=json.load(open(OUT+"/tricky-prose.json"))
def run_tricky(t):
    qs={}
    for i in t["truth"]:
        qs[f"status:{i}"]={"type":"choice","instructions":{"task":f"According to developer_notes, what is the state of the Developer's own work on scenario `{i}`?","rules":["Judge only what the notes literally state about this item; do not judge code.","Pending verification, review or live runs owned by someone else is pending_external, not unfinished.","Past or fixed incompleteness is resolved_or_historical."]},"criteria":ns["STATUS_OPTS"]}
        qs[f"objection:scenario:{i}"]={"type":"choice","instructions":{"task":f"According to developer_notes, does the Developer object that the approved contract for scenario `{i}` cannot be met as written?","rules":["Judge only what the notes state about this item.","Unfinished work alone is not an objection."]},"criteria":ns["OBJ_OPTS"]}
    return [probe.call({"model":"jev-1.13.0","state":{"developer_notes":t["notes"]},"questions":qs})[3].get("answers") for _ in range(3)]
with cf.ThreadPoolExecutor(6) as ex:
    reps=list(ex.map(lambda r:[ns["run"](r) for _ in range(2)], sample))
    tr=list(ex.map(run_tricky,T))
json.dump({"sample":[{"record":r["record"],"attempt":r["attempt"],"items":r["items"],"runs":[r["answers"]]+[x["answers"] for x in rr]} for r,rr in zip(sample,reps)],"tricky":[{"label":t["label"],"truth":t["truth"],"runs":x} for t,x in zip(T,tr)]},open(OUT+"/prose-v2-repeat.json","w"))
print("sample",len(sample),"tricky",len(T))
