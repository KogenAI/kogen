import json,glob,sys
sys.path.insert(0, sys.argv[1]); import probe
def rec(b): return json.load(open(glob.glob(f"/Users/almirsarajcic/Areas/Kogen/kogen/.kogen/runtime/scenario-tracking/{b}*/record.json")[0]))
crit={"yes":"the notes say the approved contract itself cannot be met as written (for example a required change is outside the allowed paths, scenarios contradict each other, or the required proof cannot observe the behaviour)","no":"the notes raise no such contract objection"}
for label,b,n in [("objection-named-routes-a1","Bg1qobsC",1),("objection-rvp-incomplete","-lFrRPmL",0),("objection-rvp-accepted","cDBZM4Sp",2)]:
    r=rec(b); a=r["attempts"][n]; notes=a["developer_message"]
    qs={f"cannot_comply:{k}:{e['id']}":{"type":"choice","instructions":{"task":f"Read developer_notes. Does the Developer say the approved contract for {k} `{e['id']}` cannot be met as written?","rules":["Judge only what the notes state.","Unfinished work alone is not a contract objection."]},"criteria":crit} for k,coll in (("scenario",r["scenarios"]),("risk",r.get("risks",[]))) for e in coll}
    st,lat,nb,out=probe.call({"model":"jev-1.13.0","state":{"developer_notes":notes},"questions":qs})
    json.dump({"label":label,"build":b,"attempt":n,"status":st,"response":out},open(f"{sys.argv[1]}/{label}.json","w"),indent=1)
    ys=[(k,v["confidence"]) for k,v in (out.get("answers") or {}).items() if v["choice"]=="yes"]
    print(label,st,out.get("usage"),"questions",len(qs),"yes:",ys, "min conf", min([v["confidence"] for v in out.get("answers",{}).values()] or [None]))
