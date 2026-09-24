#!/usr/bin/env python3
"""Calibrate Jev reading Developer prose. Truth = the Developer's own status field (hidden from Jev)
and hand-verified contract-objection items. Prose = claims/responses only, status fields removed."""
import json, glob, re, sys, concurrent.futures as cf
sys.path.insert(0, sys.argv[1]); import probe
OUT=sys.argv[1]; REPO="/Users/almirsarajcic/Areas/Kogen/kogen/"
OBJ=re.compile(r"return to shaping|outside the guarded paths|outside permitted edit scope|conflicts with the guarded paths", re.I)
paths=glob.glob(REPO+".kogen/runtime/scenario-tracking/*/record.json")+glob.glob(REPO+".kogen/runtime/live-evidence/**/scenario-tracking/*/record.json",recursive=True)
seen=set(); cases=[]
for p in sorted(paths):
    try: r=json.load(open(p))
    except Exception: continue
    for a in r.get("attempts",[]):
        m=a.get("developer_message")
        try: h=json.loads(m) if isinstance(m,str) else None
        except Exception: h=None
        if not isinstance(h,dict) or not isinstance(h.get("scenarios"),list) or m in seen: continue
        seen.add(m)
        lines=[]; items=[]
        def txt(e,*ks): return " ".join(str(e.get(k,"")) for k in ks)+" "+" ".join(x.get("locator","") for x in (e.get("evidence") or [])+(e.get("implementation") or []) if isinstance(x,dict))
        for s in h["scenarios"]:
            lines.append(f"Scenario {s.get('id')}: {s.get('claim','')}"); items.append(("scenario",s.get("id"),s.get("status")=="incomplete",bool(OBJ.search(txt(s,"claim")))))
        for k in h.get("risks",[]):
            lines.append(f"Risk {k.get('id')}: {k.get('response','')}"); items.append(("risk",k.get("id"),None,bool(OBJ.search(txt(k,"response")))))
        for f in h.get("findings",[]):
            lines.append(f"Finding {f.get('id')}: {f.get('response','')}"); items.append(("finding",f.get("id"),None,bool(OBJ.search(txt(f,"response")))))
        cases.append({"record":p.replace(REPO,""),"attempt":a.get("number"),"notes":"\n\n".join(lines),"items":items})
crit_u={"yes":"the notes say part of this item is still unfinished, missing or incomplete","no":"the notes present this item as done"}
crit_c={"yes":"the notes say the approved contract for this item cannot be met as written (e.g. a required change is outside the allowed paths, requirements contradict, or it needs to return to Shaping)","no":"the notes raise no such contract objection for this item"}
def run(c):
    qs={}
    for kind,i,unf,obj in c["items"]:
        if kind=="scenario":
            qs[f"unfinished:{i}"]={"type":"choice","instructions":{"task":f"Read developer_notes. Does the Developer say anything required by scenario `{i}` is still unfinished?","rules":["Judge only what the notes state; do not judge code."]},"criteria":crit_u}
        qs[f"cannot_comply:{kind}:{i}"]={"type":"choice","instructions":{"task":f"Read developer_notes. Does the Developer say the approved contract for {kind} `{i}` cannot be met as written?","rules":["Judge only what the notes state.","Unfinished work alone is not a contract objection."]},"criteria":crit_c}
    st,lat,nb,out=probe.call({"model":"jev-1.13.0","state":{"developer_notes":c["notes"]},"questions":qs})
    return {**{k:c[k] for k in ("record","attempt","items")},"status":st,"latency_s":lat,"usage":out.get("usage"),"answers":out.get("answers"),"error":out.get("error_body")}
with cf.ThreadPoolExecutor(6) as ex: res=list(ex.map(run,cases))
json.dump(res,open(f"{OUT}/prose-calibration.json","w"))
print("cases",len(res),"errors",sum(1 for r in res if r["status"]!=200))
