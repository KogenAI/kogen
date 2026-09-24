import json,glob,sys
sys.path.insert(0, sys.argv[1]); import probe
def rec(b): return json.load(open(glob.glob(f"/Users/almirsarajcic/Areas/Kogen/kogen/.kogen/runtime/scenario-tracking/{b}*/record.json")[0]))
for label,b,n in [("notes-incomplete","-lFrRPmL",0),("notes-accepted","cDBZM4Sp",2),("notes-reviewer-rework","cDBZM4Sp",0)]:
    r=rec(b); a=r["attempts"][n]; notes=a["developer_message"]
    qs={}
    for s in r["scenarios"]:
        sid=s["id"]
        qs[f"unfinished:{sid}"]={"type":"choice","instructions":{"task":f"Read developer_notes. Does the Developer say that anything required by scenario `{sid}` is still unfinished, missing or incomplete?","rules":["Judge only what the notes state; do not judge the code."]},"criteria":{"yes":"the notes say part of this scenario is unfinished","no":"the notes present this scenario as done"}}
    body={"model":"jev-1.13.0","state":{"developer_notes":notes},"questions":qs}
    st,lat,nb,out=probe.call(body)
    json.dump({"label":label,"build":b,"attempt":n,"status":st,"response":out},open(f"{sys.argv[1]}/{label}.json","w"),indent=1)
    print(label,st,out.get("usage"))
    for k,v in (out.get("answers") or {}).items(): print(" ",k,v["choice"],v["confidence"])
