#!/usr/bin/env python3
"""Prose reading v2: explicit boundary cases + confusable categories as their own Choice options (guide: literal
reading/negation -> state exact condition and boundary cases; add unresolved option). Same 294 messages as v1."""
import json, sys, concurrent.futures as cf
sys.path.insert(0, sys.argv[1]); import probe
OUT=sys.argv[1]; SRC=json.load(open(OUT+"/prose-calibration.json"))
REPO="/Users/almirsarajcic/Areas/Kogen/kogen/"
STATUS_OPTS={
 "unfinished":"The Developer states that implementation work it owns for this item is still missing, partial, stubbed or not yet done in this Candidate.",
 "done":"The Developer presents its own work for this item as complete.",
 "pending_external":"The Developer's own work is complete; what remains is verification, review, a live/paid run, or approval owned by Kogen, a Reviewer, the owner or another party.",
 "resolved_or_historical":"The notes mention incompleteness only as past history, an earlier attempt, retained evidence, or something since fixed.",
 "objection_only":"The Developer says this item cannot be met as approved (contract defect), rather than simply unfinished.",
 "unclear":"The notes do not say, or are contradictory.",
}
OBJ_OPTS={
 "objection":"The Developer says the approved contract for this item cannot be met as written: a required change is outside the allowed or guarded paths, requirements contradict, the proof cannot observe it, an assumption of the approved Intent is false, or it needs a Shaping decision.",
 "no_objection":"The notes raise no contract objection for this item. Unfinished work, pending verification or ordinary difficulties are not objections.",
 "unclear":"The notes are ambiguous about whether the contract itself is at fault.",
}
def notes_of(r):
    rec=json.load(open(REPO+r["record"])); a=[x for x in rec["attempts"] if x.get("number")==r["attempt"]][0]; h=json.loads(a["developer_message"])
    lines=[f"Scenario {s['id']}: {s.get('claim','')}" for s in h["scenarios"]]+[f"Risk {k['id']}: {k.get('response','')}" for k in h.get("risks",[])]+[f"Finding {f['id']}: {f.get('response','')}" for f in h.get("findings",[])]
    return "\n\n".join(lines)
def run(r):
    qs={}
    for kind,i,u,o in r["items"]:
        if kind=="scenario":
            qs[f"status:{i}"]={"type":"choice","instructions":{"task":f"According to developer_notes, what is the state of the Developer's own work on scenario `{i}`?","rules":["Judge only what the notes literally state about this item; do not judge code.","Pending verification, review or live runs owned by someone else is pending_external, not unfinished.","Past or fixed incompleteness is resolved_or_historical."]},"criteria":STATUS_OPTS}
        qs[f"objection:{kind}:{i}"]={"type":"choice","instructions":{"task":f"According to developer_notes, does the Developer object that the approved contract for {kind} `{i}` cannot be met as written?","rules":["Judge only what the notes state about this item.","Unfinished work alone is not an objection."]},"criteria":OBJ_OPTS}
    st,lat,nb,out=probe.call({"model":"jev-1.13.0","state":{"developer_notes":notes_of(r)},"questions":qs})
    return {"record":r["record"],"attempt":r["attempt"],"items":r["items"],"status":st,"usage":out.get("usage"),"answers":out.get("answers"),"error":out.get("error_body")}
with cf.ThreadPoolExecutor(6) as ex: res=list(ex.map(run,SRC))
json.dump(res,open(OUT+"/prose-v2.json","w")); print("done",len(res),"errors",sum(1 for x in res if x["status"]!=200))
